package postgres

import "base:runtime"

// Conn is one physical connection. It owns a libpq PGconn handle, kept as an
// opaque rawptr so the FFI type never crosses the public surface. A Conn has a
// single calling thread at a time; the bounded pool (WP77) enforces that.
//
// `_detail` is the scratch buffer that backs Error.detail for failures produced
// by this connection. It is overwritten on the next failing operation.
Conn :: struct {
	_pg:      rawptr, // pq.Conn
	_closed:  bool,
	// _broken marks a connection whose physical state is uncertain (lost mid
	// command, cancellation unconfirmed). The pool discards it; it is never
	// returned as healthy.
	_broken:  bool,
	_detail:  [128]u8,
}

// open establishes one connection using cfg. It validates the TLS/auth policy
// before opening a socket, refuses a non-thread-safe libpq, and returns a typed
// Error on any failure. The caller owns the returned Conn and must close it.
//
// WP75: skeleton. WP76 implements the body.
open :: proc(cfg: Config, loc := #caller_location) -> (Conn, Error) {
	return Conn{}, unimplemented_err("postgres.open", loc)
}

// close releases the connection's libpq handle exactly once. It is safe to call
// on a zero or already-closed Conn.
//
// WP75: skeleton. WP76 implements the body.
close :: proc(c: ^Conn) {
	// no-op until WP76
}

// ping validates connectivity and the auth/TLS policy without keeping a
// connection. It is a boot-time readiness helper, not a health endpoint.
//
// WP75: skeleton. WP76 implements the body.
ping :: proc(cfg: Config, loc := #caller_location) -> Error {
	return unimplemented_err("postgres.ping", loc)
}

// is_broken reports whether the connection's physical state is uncertain and it
// must not be reused.
is_broken :: proc "contextless" (c: ^Conn) -> bool {
	return c._broken
}

@(private)
detail_from :: proc(c: ^Conn, s: string) -> string {
	c._detail = {}
	n := min(len(s), len(c._detail))
	for i in 0 ..< n {
		c._detail[i] = s[i]
	}
	return string(c._detail[:n])
}
