package http_client

import "base:runtime"

// Error_Kind is the typed vocabulary of outbound-HTTP failures the client
// promises. Every failure is fail-closed: the client never returns a zero-value
// "success" it did not earn. In particular a certificate that does not verify is
// Tls_Cert_Invalid, never a Response.
Error_Kind :: enum u32 {
	None = 0,

	// The client surface exists but the body is not written yet. Used to hold the
	// A1 contract RED-under-control; no green test may accept it.
	Unimplemented,

	// Configuration rejected before any socket is opened (max_conns < 1, a
	// negative timeout, a plaintext-only field mismatch).
	Config_Invalid,

	// The target could not be parsed into scheme/host/port, or names an
	// unsupported scheme or address family.
	Invalid_Url,

	// The TCP connection could not be established for a non-timeout reason
	// (refused, host unreachable, DNS failure).
	Connect_Failed,

	// The per-connect deadline elapsed before the TCP handshake completed.
	Connect_Timeout,

	// The per-request deadline elapsed while sending the request or reading the
	// response.
	Request_Timeout,

	// The overall deadline budget for the call elapsed (across connect, TLS,
	// send, receive and any retries).
	Deadline_Exceeded,

	// The bounded in-flight pool had no slot within the acquire deadline, and the
	// bounded waiter set was full. This is the typed "Full": the client refuses
	// rather than growing without bound or blocking forever.
	Pool_Exhausted,

	// A drain/close cancelled this request. In-flight sockets are shut down; a
	// request that observed the drain returns this instead of a partial Response.
	Canceled,

	// The TLS handshake failed for a non-verification reason (protocol/setup).
	Tls_Failed,

	// Certificate verification REFUSED the peer: a self-signed, expired, or
	// wrong-hostname certificate, or a chain that does not build to the trust
	// store. This is the security invariant — it is a failure, never a Response.
	Tls_Cert_Invalid,

	// The request bytes could not be written to the peer.
	Send_Failed,

	// The response could not be read off the peer (connection reset/closed mid
	// response).
	Recv_Failed,

	// The peer's response could not be parsed as HTTP/1.1.
	Protocol_Violation,

	// The response body exceeded the configured max_response_bytes bound.
	Response_Too_Large,

	// The client or its pool was already closed.
	Closed,

	// Any failure the client cannot place.
	Unknown,
}

// Error is small and returned by value alongside every fallible operation. It
// carries a stable kind, a caller-safe operation name, and a caller-safe detail
// fragment. It never carries request bodies, credentials, header values, or the
// raw OpenSSL error string.
Error :: struct {
	kind:   Error_Kind,
	op:     string,
	detail: string,
	loc:    runtime.Source_Code_Location,
}

// is_err reports whether an operation failed.
is_err :: proc "contextless" (e: Error) -> bool {
	return e.kind != .None
}

@(private)
err :: proc(kind: Error_Kind, op: string, loc: runtime.Source_Code_Location, detail := "") -> Error {
	return Error{kind = kind, op = op, detail = detail, loc = loc}
}
