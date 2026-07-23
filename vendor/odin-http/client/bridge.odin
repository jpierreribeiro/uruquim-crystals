package client

// URUQUIM CRYSTALS BRIDGE PATCH 2 (Phase 7.5-A2/A3): expose the upstream
// HTTP/1.1 message layer to the http_client contract.
//
// The reusable, tested value of the upstream client is its request formatter
// (format_request) and its response parser (parse_response, which handles the
// status line, headers, cookies, and content-length / chunked bodies). Both,
// and the Communication union they operate over, are declared `#+private` in
// communication.odin, so the contract package cannot call them.
//
// This file re-exports exactly those symbols under `bridge_*` names, and adds
// two constructors so the contract can build a Communication from a socket it
// dialed and verified itself (the private struct fields are only visible here,
// inside the package). Nothing about the upstream message parsing is changed —
// the contract keeps ownership of connect timeouts, the deadline budget, the
// bounded pool, drain cancellation, and TLS verification. Additive only;
// deletable with the bridge at the core:net/http transition (ADR-033).

import "core:bytes"
import "core:net"
import http ".."
import openssl "../openssl"

// The request method type, re-exported so the contract can name it without
// importing the whole http package.
Method :: http.Method

// Force `connection: close` on a request (upstream has no keep-alive client).
bridge_set_close :: proc(h: ^http.Headers) {
	http.headers_set_close(h)
}

// The URL type the formatter/parser operate over.
Bridge_URL :: http.URL

// The socket/SSL carrier the parser reads the response over.
Bridge_Comm :: Communication

// Resolve a target URL to a concrete endpoint (DNS + default port for the
// scheme). Returns the parsed URL so the contract can read scheme/host/path.
// (Thin wrappers, not aliases: the wrapped procs are package-private, and a
// bare alias does not re-export them.)
bridge_parse_endpoint :: proc(target: string) -> (http.URL, net.Endpoint, net.Network_Error) {
	return parse_endpoint(target)
}

// Serialize a Request into HTTP/1.1 wire bytes for the given target URL.
bridge_format_request :: proc(target: http.URL, request: ^Request, allocator := context.allocator) -> bytes.Buffer {
	return format_request(target, request, allocator)
}

// Parse an HTTP/1.1 response off an established (already connected and, for
// https, already verified) carrier.
bridge_parse_response :: proc(comm: Communication, allocator := context.allocator) -> (Response, Error) {
	return parse_response(comm, allocator)
}

// Build a plaintext carrier from a dialed TCP socket.
bridge_tcp_comm :: proc(sock: net.TCP_Socket) -> Communication {
	return sock
}

// Build a TLS carrier from a handshaked, verified SSL together with its context
// and underlying socket (all three are freed together by response_destroy).
bridge_ssl_comm :: proc(ssl: ^openssl.SSL, ctx: ^openssl.SSL_CTX, sock: net.TCP_Socket) -> Communication {
	return SSL_Communication{socket = sock, ssl = ssl, ctx = ctx}
}
