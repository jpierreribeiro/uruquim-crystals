package postgres

// Ssl_Mode selects the transport-security policy. Production TCP defaults to
// Verify_Full: certificate and hostname verification against a system or
// explicit CA, with no silent plaintext fallback and no "prefer" middle ground.
// Disable exists only for the explicit local plaintext test profile and is
// refused unless `allow_plaintext` is also set.
Ssl_Mode :: enum u8 {
	Verify_Full = 0, // certificate + hostname (default, production)
	Verify_Ca,       // certificate chain only
	Require,         // encryption without certificate verification
	Disable,         // plaintext; requires allow_plaintext
}

// Config is the structured, injection-free description of one connection. The
// wrapper turns it into a libpq keyword/value array; it never concatenates a
// DSN string, so a value can never smuggle a second connection parameter.
//
// The accepted password mechanism is SCRAM-SHA-256. `require_auth` is fixed by
// the wrapper so a server cannot downgrade to MD5 or cleartext. Channel binding
// is required whenever TLS verification is active and is disabled only for the
// Disable test profile.
Config :: struct {
	host:            string,
	port:            u16,
	user:            string,
	password:        string,
	database:        string,

	ssl_mode:        Ssl_Mode,
	ssl_root_cert:   string, // CA bundle path; "" uses the system store
	ssl_cert:        string, // optional client certificate path
	ssl_key:         string, // optional client key path

	// allow_plaintext must be explicitly true to accept Ssl_Mode.Disable. It
	// exists so the pinned local test harness can run without TLS while every
	// production path refuses plaintext by construction.
	allow_plaintext: bool,

	// connect_timeout_ms bounds the connection attempt. 0 uses the wrapper's
	// default; it is never unbounded.
	connect_timeout_ms: int,

	// statement_timeout_ms sets a server-side statement_timeout on every command
	// this connection runs, so a query is bounded even without a per-call
	// deadline. 0 leaves it unset. A per-query Query_Opts.deadline_ms adds a
	// tighter client-side cancellation on top.
	statement_timeout_ms: int,
}

// DEFAULT_CONNECT_TIMEOUT_MS is used when Config.connect_timeout_ms is 0.
DEFAULT_CONNECT_TIMEOUT_MS :: 10_000
