package http_client

import client "crystals:vendor/odin-http/client"

// Method is the request method. It aliases the vendored bridge's method type so
// the contract does not leak the bridge into its own name, while staying wire
// compatible with the formatter.
Method :: client.Method

DEFAULT_CONNECT_TIMEOUT_MS  :: 5_000
DEFAULT_REQUEST_TIMEOUT_MS  :: 15_000
DEFAULT_DEADLINE_MS         :: 30_000
DEFAULT_MAX_RESPONSE_BYTES  :: 8 * 1024 * 1024
DEFAULT_MAX_CONNS           :: 32

// Tls_Mode is the outbound TLS policy. Verify_Full is the only production value:
// SNI is sent, and the peer certificate's chain and hostname are verified
// against the trust store. Insecure_No_Verify disables verification and is
// accepted ONLY when the config also sets allow_insecure_tls — it exists so a
// test can prove the difference between verifying and not, never as a
// convenience. There is no way to reach it by accident.
Tls_Mode :: enum {
	Verify_Full = 0,
	Insecure_No_Verify,
}

// Config bounds and shapes a client. Every timeout has a non-zero default; none
// is ever unbounded. max_conns is the hard cap on simultaneous in-flight
// requests — beyond it, and beyond the bounded waiter set, request returns the
// typed Pool_Exhausted.
Config :: struct {
	// max_conns is the hard cap on simultaneous in-flight requests. Must be >= 1.
	max_conns:          int,
	// max_waiters caps callers blocked waiting for a slot. Beyond it, request
	// returns Pool_Exhausted immediately. 0 derives a bound from max_conns.
	max_waiters:        int,
	// acquire_timeout_ms bounds how long request waits for a slot. 0 defaults to
	// DEFAULT_REQUEST_TIMEOUT_MS; never unbounded.
	acquire_timeout_ms: int,
	// connect_timeout_ms bounds the TCP (and, for https, the TLS) handshake.
	connect_timeout_ms: int,
	// request_timeout_ms bounds sending the request and reading the response.
	request_timeout_ms: int,
	// deadline_ms bounds the whole call across connect, TLS, send, receive and
	// any retries. 0 defaults to DEFAULT_DEADLINE_MS.
	deadline_ms:        int,
	// max_response_bytes bounds the response body. 0 defaults to
	// DEFAULT_MAX_RESPONSE_BYTES.
	max_response_bytes: int,
	// max_retries bounds automatic retries of idempotent (GET/HEAD) requests on
	// a connect/receive failure. Retry is AT-LEAST-ONCE: a retried request may
	// have already been received by the origin, so a non-idempotent request is
	// never retried, and even a GET may be delivered more than once. 0 disables.
	max_retries:        int,
	// tls selects the outbound TLS policy. The zero value is Verify_Full.
	tls:                Tls_Mode,
	// allow_insecure_tls must be true for tls == Insecure_No_Verify to be
	// honored. Without it, an insecure policy is a Config_Invalid error.
	allow_insecure_tls: bool,
	// tls_ca_file is an optional additional CA anchor (PEM) merged with the
	// system trust store — for pinned/enterprise roots and test fixtures. Empty
	// uses the system trust store alone.
	tls_ca_file:        string,
}

@(private)
normalize_config :: proc(cfg: Config) -> (Config, Error_Kind) {
	c := cfg
	if c.max_conns < 1 {
		return c, .Config_Invalid
	}
	if c.max_waiters < 0 {
		return c, .Config_Invalid
	}
	if c.connect_timeout_ms < 0 || c.request_timeout_ms < 0 || c.deadline_ms < 0 ||
	   c.acquire_timeout_ms < 0 || c.max_response_bytes < 0 || c.max_retries < 0 {
		return c, .Config_Invalid
	}
	if c.tls == .Insecure_No_Verify && !c.allow_insecure_tls {
		return c, .Config_Invalid
	}
	if c.max_waiters == 0 {
		c.max_waiters = c.max_conns * 8 + 8
	}
	if c.acquire_timeout_ms == 0 {
		c.acquire_timeout_ms = DEFAULT_REQUEST_TIMEOUT_MS
	}
	if c.connect_timeout_ms == 0 {
		c.connect_timeout_ms = DEFAULT_CONNECT_TIMEOUT_MS
	}
	if c.request_timeout_ms == 0 {
		c.request_timeout_ms = DEFAULT_REQUEST_TIMEOUT_MS
	}
	if c.deadline_ms == 0 {
		c.deadline_ms = DEFAULT_DEADLINE_MS
	}
	if c.max_response_bytes == 0 {
		c.max_response_bytes = DEFAULT_MAX_RESPONSE_BYTES
	}
	return c, .None
}
