package http_client

import "base:runtime"
import "core:bytes"
import "core:net"
import "core:time"
import client "crystals:vendor/odin-http/client"

// Response is an owned snapshot of an HTTP response. The body is copied out of
// the bridge and owned by the caller; the underlying socket/TLS session is
// already closed by the time request returns. Free it with response_destroy.
Response :: struct {
	status:     int, // numeric HTTP status code
	body:       []byte, // owned response body (may be nil/empty)
	_allocator: runtime.Allocator,
}

// response_destroy frees an owned Response body.
response_destroy :: proc(r: ^Response) {
	if r.body != nil {
		delete(r.body, r._allocator)
	}
	r.body = nil
}

// get is the convenience for an idempotent GET.
get :: proc(
	c: ^Client,
	target: string,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	Response,
	Error,
) {
	return request(c, .Get, target, nil, allocator, loc)
}

// request performs one HTTP/1.1 request against target, over the bounded pool,
// under the connect/request/deadline budget, refusing an unverified TLS peer.
//
// Retry is bounded and AT-LEAST-ONCE: only idempotent methods (GET/HEAD) are
// retried, and only on a connect/receive failure, up to max_retries within the
// remaining deadline. Because a retried request may already have reached the
// origin, even a GET can be delivered more than once — callers that cannot
// tolerate that must set max_retries = 0.
request :: proc(
	c: ^Client,
	method: Method,
	target: string,
	body: []byte = nil,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	Response,
	Error,
) {
	overall_start := time.tick_now()
	overall := time.Duration(c._cfg.deadline_ms) * time.Millisecond

	idempotent := method == .Get || method == .Head
	attempts := 1
	if idempotent {
		attempts = c._cfg.max_retries + 1
	}

	last := err(.Unknown, "http_client.request", loc)
	for attempt in 0 ..< attempts {
		remaining := overall - time.tick_since(overall_start)
		if remaining <= 0 {
			return Response{}, err(.Deadline_Exceeded, "http_client.request", loc)
		}

		resp, e := do_request(c, method, target, body, remaining, allocator, loc)
		if !is_err(e) {
			return resp, Error{}
		}
		last = e

		// Only transient network failures are retryable; a typed refusal
		// (Pool_Exhausted, Tls_Cert_Invalid, Canceled, Response_Too_Large, …) is
		// returned as-is, never retried.
		retryable := e.kind == .Connect_Failed || e.kind == .Connect_Timeout || e.kind == .Recv_Failed
		if !retryable {
			return Response{}, e
		}
	}
	return Response{}, last
}

@(private)
do_request :: proc(
	c: ^Client,
	method: Method,
	target: string,
	body: []byte,
	budget: time.Duration,
	allocator: runtime.Allocator,
	loc: runtime.Source_Code_Location,
) -> (
	Response,
	Error,
) {
	start := time.tick_now()
	remaining :: proc(start: time.Tick, budget: time.Duration) -> time.Duration {
		return budget - time.tick_since(start)
	}

	// Bounded pool: acquire a slot within min(acquire, budget) or fail with the
	// typed Pool_Exhausted / Canceled / Closed.
	acq := min(time.Duration(c._cfg.acquire_timeout_ms) * time.Millisecond, budget)
	if e := acquire_slot(c, acq, loc); is_err(e) {
		return Response{}, e
	}
	defer release_slot(c)

	if is_draining(c) {
		return Response{}, err(.Canceled, "http_client.request", loc)
	}

	url, endpoint, perr := client.bridge_parse_endpoint(target)
	if perr != nil {
		return Response{}, err(.Invalid_Url, "http_client.request", loc)
	}
	is_https := url.scheme == "https"
	if url.scheme != "http" && url.scheme != "https" {
		return Response{}, err(.Invalid_Url, "http_client.request", loc)
	}

	// Connect under min(connect_timeout, remaining budget).
	connect_budget := min(time.Duration(c._cfg.connect_timeout_ms) * time.Millisecond, remaining(start, budget))
	if connect_budget <= 0 {
		return Response{}, err(.Deadline_Exceeded, "http_client.request", loc)
	}
	sock, dk := dial_timeout(endpoint, int(connect_budget / time.Millisecond))
	if dk != .None {
		return Response{}, err(dk, "http_client.request", loc)
	}

	// Register the socket so a concurrent drain can shut it down and unblock a
	// read. If a drain already started, abandon as Canceled.
	if !register_active(c, sock) {
		net.close(sock)
		return Response{}, err(.Canceled, "http_client.request", loc)
	}
	defer unregister_active(c, sock)

	// Per-request I/O deadline (also bounds the TLS handshake reads/writes).
	req_budget := min(time.Duration(c._cfg.request_timeout_ms) * time.Millisecond, remaining(start, budget))
	if req_budget <= 0 {
		net.close(sock)
		return Response{}, err(.Deadline_Exceeded, "http_client.request", loc)
	}
	net.set_option(sock, .Receive_Timeout, req_budget)
	net.set_option(sock, .Send_Timeout, req_budget)

	// Build the request bytes with the vendored formatter.
	r: client.Request
	client.request_init(&r, method, allocator)
	defer client.request_destroy(&r)
	client.bridge_set_close(&r.headers)
	if len(body) > 0 {
		bytes.buffer_write(&r.body, body)
	}
	req_buf := client.bridge_format_request(url, &r, allocator)
	defer bytes.buffer_destroy(&req_buf)
	wire := bytes.buffer_to_bytes(&req_buf)

	comm: client.Bridge_Comm
	if is_https {
		// url.host carries the authority (host[:port]); SNI and RFC 6125 hostname
		// verification need the BARE host, or a good cert for DNS:localhost is
		// rejected as a mismatch against "localhost:PORT". split_port also handles
		// bracketed IPv6 literals.
		tls_host := url.host
		if h, _, ok := net.split_port(url.host); ok {
			tls_host = h
		}
		ssl, ctx, terr := tls_connect(sock, tls_host, c._cfg, loc)
		if is_err(terr) {
			net.close(sock)
			return Response{}, terr
		}
		if !ssl_write_all(ssl, wire) {
			tls_free(ssl, ctx)
			net.close(sock)
			return Response{}, err(.Send_Failed, "http_client.request", loc)
		}
		comm = client.bridge_ssl_comm(ssl, ctx, sock)
	} else {
		if _, serr := net.send_tcp(sock, wire); serr != nil {
			net.close(sock)
			return Response{}, err(.Send_Failed, "http_client.request", loc)
		}
		comm = client.bridge_tcp_comm(sock)
	}

	// Read and parse the response off the carrier. response_destroy(&res) closes
	// the socket/TLS session regardless of the parse outcome.
	res, rerr := client.bridge_parse_response(comm, allocator)
	if rerr != nil {
		client.response_destroy(&res)
		if is_draining(c) {
			return Response{}, err(.Canceled, "http_client.request", loc)
		}
		// A read that blocked for the whole per-request budget then failed is a
		// timeout (the socket receive deadline fired); a fast failure is a reset.
		if time.tick_since(start) >= req_budget {
			return Response{}, err(.Request_Timeout, "http_client.request", loc)
		}
		return Response{}, err(.Recv_Failed, "http_client.request", loc)
	}

	// Bounded body read.
	bt, was_alloc, berr := client.response_body(&res, c._cfg.max_response_bytes, allocator)
	if berr == .Too_Long {
		client.response_destroy(&res)
		return Response{}, err(.Response_Too_Large, "http_client.request", loc)
	}

	out := Response {
		status     = int(res.status),
		_allocator = allocator,
	}
	if berr == .None {
		#partial switch b in bt {
		case client.Body_Plain:
			s := string(b)
			if len(s) > 0 {
				out.body = make([]byte, len(s), allocator)
				copy(out.body, s)
			}
		}
	}

	// Free the bridge body (if any) and close the connection.
	if berr == .None {
		client.response_destroy(&res, bt, was_alloc, allocator)
	} else {
		client.response_destroy(&res)
	}
	return out, Error{}
}
