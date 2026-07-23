// http_client contract corpus: the plaintext path, the bounded pool's typed
// Pool_Exhausted, connect/request timeouts, refusal, and drain cancellation.
// TLS certificate verification lives in tests/http_client_tls (it needs real
// OpenSSL peers, wired by build/check_http_client_controls.sh).
//
// A local raw-TCP origin stands in for a real server: it reads the request,
// optionally holds (to occupy a pool slot or block a read across a drain), then
// replies with a canned HTTP/1.1 response.
package test_http_client

import "base:intrinsics"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import hc "crystals:http_client"

// --- controllable local origin ---------------------------------------------

Origin :: struct {
	listener: net.TCP_Socket,
	port:     int,
	accept_t: ^thread.Thread,
	stop:     i32,
	hold:     bool, // if set, handlers wait on `release` before replying
	release:  sync.Sema,
	arrived:  sync.Sema, // posted once per handled request, after the request is read
	body:     string,
	mu:       sync.Mutex,
	conns:    [dynamic]net.TCP_Socket,
	handlers: [dynamic]^thread.Thread,
}

@(private)
origin_handle :: proc(using_conn: ^Handler_Arg) {
	o := using_conn.o
	conn := using_conn.conn
	free(using_conn)

	net.set_option(conn, .Receive_Timeout, 2 * time.Second)
	buf: [4096]u8
	acc: strings.Builder
	strings.builder_init(&acc)
	defer strings.builder_destroy(&acc)
	for !strings.contains(strings.to_string(acc), "\r\n\r\n") {
		n, e := net.recv_tcp(conn, buf[:])
		if n > 0 {strings.write_bytes(&acc, buf[:n])}
		if n == 0 || e != nil {break}
	}
	sync.sema_post(&o.arrived)

	if o.hold {
		sync.sema_wait(&o.release)
	}
	if intrinsics.atomic_load(&o.stop) == 0 {
		clen := itoa(len(o.body))
		defer delete(clen)
		resp := strings.concatenate(
			{"HTTP/1.1 200 OK\r\nContent-Length: ", clen, "\r\nConnection: close\r\n\r\n", o.body},
		)
		defer delete(resp)
		net.send_tcp(conn, transmute([]u8)resp)
	}
	net.close(conn)
}

Handler_Arg :: struct {
	o:    ^Origin,
	conn: net.TCP_Socket,
}

@(private)
origin_accept :: proc(o: ^Origin) {
	for intrinsics.atomic_load(&o.stop) == 0 {
		conn, _, e := net.accept_tcp(o.listener)
		if e != nil {break}
		if intrinsics.atomic_load(&o.stop) != 0 {net.close(conn);break}
		sync.mutex_lock(&o.mu)
		append(&o.conns, conn)
		arg := new(Handler_Arg)
		arg.o = o
		arg.conn = conn
		ht := thread.create_and_start_with_poly_data(arg, origin_handle)
		append(&o.handlers, ht)
		sync.mutex_unlock(&o.mu)
	}
}

@(private)
origin_start :: proc(o: ^Origin) -> bool {
	// Bind an ephemeral port on loopback.
	for port := 34000; port < 34100; port += 1 {
		l, e := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}, 128)
		if e == nil {
			o.listener = l
			o.port = port
			o.conns = make([dynamic]net.TCP_Socket)
			o.handlers = make([dynamic]^thread.Thread)
			o.accept_t = thread.create_and_start_with_poly_data(o, origin_accept)
			return true
		}
	}
	return false
}

@(private)
origin_stop :: proc(o: ^Origin) {
	intrinsics.atomic_store(&o.stop, 1)
	// Release any held handlers so they can exit.
	for _ in 0 ..< 64 {sync.sema_post(&o.release)}
	// Unblock the accept() with a throwaway self-connection; closing the
	// listener alone does not reliably wake a blocked accept on Linux.
	if s, e := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = o.port}); e == nil {
		net.close(s)
	}
	net.close(o.listener)
	sync.mutex_lock(&o.mu)
	for c in o.conns {net.shutdown(c, net.Shutdown_Manner.Both)}
	handlers := o.handlers
	sync.mutex_unlock(&o.mu)
	for ht in handlers {thread.join(ht);thread.destroy(ht)}
	if o.accept_t != nil {thread.join(o.accept_t);thread.destroy(o.accept_t)}
	delete(o.conns)
	delete(o.handlers)
}

@(private)
itoa :: proc(n: int) -> string {
	if n == 0 {return "0"}
	buf: [20]u8
	i := len(buf)
	m := n
	for m > 0 {i -= 1;buf[i] = u8('0' + m % 10);m /= 10}
	return strings.clone(string(buf[i:]))
}

@(private)
url_for :: proc(port: int) -> string {
	p := itoa(port)
	defer delete(p)
	return strings.concatenate({"http://127.0.0.1:", p, "/"})
}

// --- A2: the plaintext happy path -------------------------------------------

@(test)
test_plaintext_get_ok :: proc(t: ^testing.T) {
	o := Origin{body = "hello-uruquim"}
	testing.expect(t, origin_start(&o), "origin did not start")
	defer origin_stop(&o)

	c, oe := hc.open(hc.Config{max_conns = 4})
	testing.expect(t, !hc.is_err(oe), "client open failed")
	defer hc.close(&c)

	target := url_for(o.port)
	defer delete(target)
	resp, e := hc.get(&c, target)
	defer hc.response_destroy(&resp)

	testing.expectf(t, !hc.is_err(e), "get failed: %v", e.kind)
	testing.expect_value(t, resp.status, 200)
	testing.expect_value(t, string(resp.body), "hello-uruquim")
}

// --- A2: connection refused -------------------------------------------------

@(test)
test_connection_refused :: proc(t: ^testing.T) {
	// Bind then close a port to obtain one that is definitely not listening.
	l, e := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 34199}, 1)
	testing.expect(t, e == nil, "could not bind probe port")
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 34199}
	net.close(l)
	_ = ep

	c, _ := hc.open(hc.Config{max_conns = 2})
	defer hc.close(&c)
	target := url_for(34199)
	defer delete(target)
	resp, re := hc.get(&c, target)
	defer hc.response_destroy(&resp)
	testing.expect_value(t, re.kind, hc.Error_Kind.Connect_Failed)
}

// --- A2: connect timeout (black-holed TEST-NET address, RFC 5737) -----------

@(test)
test_connect_timeout :: proc(t: ^testing.T) {
	c, _ := hc.open(hc.Config{max_conns = 2, connect_timeout_ms = 500, deadline_ms = 10_000})
	defer hc.close(&c)

	start := time.tick_now()
	resp, e := hc.get(&c, "http://192.0.2.1:80/")
	defer hc.response_destroy(&resp)
	elapsed := time.tick_since(start)

	testing.expect_value(t, e.kind, hc.Error_Kind.Connect_Timeout)
	testing.expectf(t, elapsed < 3 * time.Second, "connect timeout took too long: %v", elapsed)
}

// --- A2: per-request read timeout (hermetic) --------------------------------

@(test)
test_request_timeout :: proc(t: ^testing.T) {
	// The vendored parser logs the timed-out read at error level; that is not the
	// contract's concern (the contract returns Request_Timeout), so quiet the
	// logger the test runner watches.
	context.logger = log.nil_logger()

	o := Origin{body = "never-sent", hold = true}
	testing.expect(t, origin_start(&o), "origin did not start")
	defer origin_stop(&o)

	c, _ := hc.open(hc.Config{max_conns = 2, request_timeout_ms = 300, deadline_ms = 10_000})
	defer hc.close(&c)
	target := url_for(o.port)
	defer delete(target)

	start := time.tick_now()
	resp, e := hc.get(&c, target)
	defer hc.response_destroy(&resp)
	elapsed := time.tick_since(start)

	testing.expect_value(t, e.kind, hc.Error_Kind.Request_Timeout)
	testing.expectf(t, elapsed < 3 * time.Second, "request timeout took too long: %v", elapsed)
}

// --- A2: the bounded pool refuses with the typed Pool_Exhausted -------------

Fire_Arg :: struct {
	c:      ^hc.Client,
	target: string,
	done:   sync.Sema,
	result: hc.Error_Kind,
}

@(private)
fire :: proc(fa: ^Fire_Arg) {
	resp, e := hc.get(fa.c, fa.target)
	hc.response_destroy(&resp)
	fa.result = e.kind
	sync.sema_post(&fa.done)
}

@(test)
test_pool_exhausted_is_typed :: proc(t: ^testing.T) {
	o := Origin{body = "ok", hold = true}
	testing.expect(t, origin_start(&o), "origin did not start")
	defer origin_stop(&o)

	// One slot, no waiter room: a second concurrent request must refuse at once.
	c, _ := hc.open(hc.Config{max_conns = 1, max_waiters = 1, acquire_timeout_ms = 500})
	defer hc.close(&c)
	target := url_for(o.port)
	defer delete(target)

	// Thread A grabs the only slot and blocks reading (origin holds).
	fa := Fire_Arg{c = &c, target = target}
	ft := thread.create_and_start_with_poly_data(&fa, fire)
	sync.sema_wait(&o.arrived) // the origin has read A's request → A holds the slot

	// A second request while the slot is held returns the typed Full.
	resp2, e2 := hc.get(&c, target)
	hc.response_destroy(&resp2)
	testing.expect_value(t, e2.kind, hc.Error_Kind.Pool_Exhausted)

	// Let A complete.
	sync.sema_post(&o.release)
	sync.sema_wait(&fa.done)
	thread.join(ft)
	thread.destroy(ft)
	testing.expect_value(t, fa.result, hc.Error_Kind.None)
}

// --- A2: drain cancels an in-flight request ---------------------------------

@(test)
test_drain_cancels_in_flight :: proc(t: ^testing.T) {
	o := Origin{body = "ok", hold = true}
	testing.expect(t, origin_start(&o), "origin did not start")
	defer origin_stop(&o)

	c, _ := hc.open(hc.Config{max_conns = 2, request_timeout_ms = 10_000, deadline_ms = 20_000})
	target := url_for(o.port)
	defer delete(target)

	fa := Fire_Arg{c = &c, target = target}
	ft := thread.create_and_start_with_poly_data(&fa, fire)
	sync.sema_wait(&o.arrived) // request is in-flight, blocked on the held read

	// Drain: close() must shut the in-flight socket down and the request must
	// observe the drain and return Canceled — not hang to the 10s read timeout.
	start := time.tick_now()
	hc.close(&c)
	sync.sema_wait(&fa.done)
	elapsed := time.tick_since(start)
	thread.join(ft)
	thread.destroy(ft)

	testing.expect_value(t, fa.result, hc.Error_Kind.Canceled)
	testing.expectf(t, elapsed < 3 * time.Second, "drain did not promptly cancel: %v", elapsed)
}
