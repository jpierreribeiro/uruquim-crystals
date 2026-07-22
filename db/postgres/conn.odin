package postgres

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import pq "crystals:vendor/odin-postgresql"

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
// before opening a socket, refuses a non-thread-safe libpq, forces SCRAM-SHA-256
// so a server cannot downgrade the password mechanism, and returns a typed Error
// on any failure. The caller owns the returned Conn and must close it.
open :: proc(cfg: Config, loc := #caller_location) -> (Conn, Error) {
	if k := validate_config(cfg); k != .None {
		return Conn{}, err(k, "postgres.open", loc)
	}
	if pq.is_thread_safe() != 1 {
		return Conn{}, err(.Not_Thread_Safe, "postgres.open", loc)
	}

	arena: virtual.Arena
	ally := scratch(&arena)
	defer virtual.arena_destroy(&arena)

	keywords, values := build_conninfo(ally, cfg)
	conn := pq.connectdb_params(raw_data(keywords), raw_data(values), false)
	if conn == nil {
		return Conn{}, err(.Connect_Failed, "postgres.open", loc)
	}
	if pq.status(conn) != .Ok {
		kind := classify_connect_failure(conn)
		pq.finish(conn)
		return Conn{}, err(kind, "postgres.open", loc)
	}
	return Conn{_pg = rawptr(conn)}, Error{}
}

// close releases the connection's libpq handle exactly once. Safe on a zero or
// already-closed Conn.
close :: proc(c: ^Conn) {
	if c._pg != nil {
		pq.finish(pq.Conn(c._pg))
		c._pg = nil
	}
	c._closed = true
}

// ping validates connectivity and the auth/TLS policy without keeping a
// connection. It is a boot-time readiness helper, not a health endpoint.
ping :: proc(cfg: Config, loc := #caller_location) -> Error {
	c, e := open(cfg, loc)
	if is_err(e) {
		return e
	}
	close(&c)
	return Error{}
}

// is_broken reports whether the connection's physical state is uncertain and it
// must not be reused.
is_broken :: proc "contextless" (c: ^Conn) -> bool {
	return c._broken
}

@(private)
validate_config :: proc(cfg: Config) -> Error_Kind {
	if cfg.host == "" || cfg.user == "" || cfg.database == "" {
		return .Config_Invalid
	}
	if cfg.ssl_mode == .Disable && !cfg.allow_plaintext {
		return .Config_Invalid
	}
	return .None
}

@(private)
ssl_mode_string :: proc "contextless" (m: Ssl_Mode) -> string {
	switch m {
	case .Verify_Full:
		return "verify-full"
	case .Verify_Ca:
		return "verify-ca"
	case .Require:
		return "require"
	case .Disable:
		return "disable"
	}
	return "verify-full"
}

// build_conninfo assembles nil-terminated keyword/value arrays. Values never
// concatenate into a DSN string, so no value can smuggle a second parameter.
// require_auth pins SCRAM-SHA-256; channel binding is required whenever TLS
// verification is active and disabled only for the plaintext test profile.
@(private)
build_conninfo :: proc(ally: runtime.Allocator, cfg: Config) -> (keywords: []cstring, values: []cstring) {
	kw: [dynamic]cstring
	vs: [dynamic]cstring
	kw.allocator = ally
	vs.allocator = ally

	add :: proc(kw, vs: ^[dynamic]cstring, ally: runtime.Allocator, k: cstring, v: string) {
		c, _ := strings.clone_to_cstring(v, ally)
		append(kw, k)
		append(vs, c)
	}

	port := cfg.port if cfg.port != 0 else 5432
	timeout_ms := cfg.connect_timeout_ms if cfg.connect_timeout_ms > 0 else DEFAULT_CONNECT_TIMEOUT_MS
	timeout_s := (timeout_ms + 999) / 1000
	if timeout_s < 1 {
		timeout_s = 1
	}

	add(&kw, &vs, ally, "host", cfg.host)
	add(&kw, &vs, ally, "port", fmt_uint(ally, u64(port)))
	add(&kw, &vs, ally, "user", cfg.user)
	if cfg.password != "" {
		add(&kw, &vs, ally, "password", cfg.password)
	}
	add(&kw, &vs, ally, "dbname", cfg.database)
	add(&kw, &vs, ally, "sslmode", ssl_mode_string(cfg.ssl_mode))
	add(&kw, &vs, ally, "require_auth", "scram-sha-256")
	add(&kw, &vs, ally, "channel_binding", cfg.ssl_mode == .Disable ? "disable" : "require")
	add(&kw, &vs, ally, "connect_timeout", fmt_uint(ally, u64(timeout_s)))
	add(&kw, &vs, ally, "application_name", "uruquim-crystals")
	if cfg.ssl_root_cert != "" {
		add(&kw, &vs, ally, "sslrootcert", cfg.ssl_root_cert)
	}
	if cfg.ssl_cert != "" {
		add(&kw, &vs, ally, "sslcert", cfg.ssl_cert)
	}
	if cfg.ssl_key != "" {
		add(&kw, &vs, ally, "sslkey", cfg.ssl_key)
	}

	append(&kw, cstring(nil))
	append(&vs, cstring(nil))
	return kw[:], vs[:]
}

// classify_connect_failure inspects (but never stores) libpq's connection error
// text only to choose a typed kind. The message itself is diagnostic detail and
// stays out of the Error.
@(private)
classify_connect_failure :: proc(conn: pq.Conn) -> Error_Kind {
	msg := string(pq.error_message(conn))
	if contains_any(msg, {"authentication", "password", "require_auth", "SCRAM", "auth method"}) {
		return .Auth_Failed
	}
	if contains_any(msg, {"SSL", "TLS", "certificate", "channel binding"}) {
		return .Tls_Failed
	}
	return .Connect_Failed
}

@(private)
contains_any :: proc(haystack: string, needles: []string) -> bool {
	for n in needles {
		if strings.contains(haystack, n) {
			return true
		}
	}
	return false
}

@(private)
fmt_uint :: proc(ally: runtime.Allocator, v: u64) -> string {
	buf := make([]byte, 24, ally)
	i := len(buf)
	n := v
	if n == 0 {
		return "0"
	}
	for n > 0 {
		i -= 1
		buf[i] = byte('0' + n % 10)
		n /= 10
	}
	return string(buf[i:])
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
