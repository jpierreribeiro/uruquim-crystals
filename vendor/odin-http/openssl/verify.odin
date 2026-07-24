package openssl

// URUQUIM CRYSTALS BRIDGE PATCH 1 (Phase 7.5-A3): outbound certificate
// verification FFI.
//
// Upstream's client (client/client.odin) calls SSL_connect on a default context
// that performs NO peer verification: a self-signed, expired, or wrong-host
// certificate is silently accepted. That is the exact security hole the
// http_client contract must close. These declarations add the OpenSSL calls the
// contract uses to make verification an inseparable, fail-closed part of every
// https connection — peer-verification mode, the system trust store, an optional
// extra CA anchor, RFC 6125 hostname checking, and the post-handshake verdict.
//
// No crypto is implemented here; these are FFI declarations over the system
// libssl.so.3 / libcrypto.so.3. This whole bridge is deletable at the
// core:net/http transition (ADR-033).
//
// Kept in a separate file (rather than editing the upstream snapshot) so the
// vendored openssl.odin stays byte-faithful and the patch is auditable on its
// own.

import "core:c"

when ODIN_OS == .Darwin {
	foreign import verifylib {
		"system:ssl.3",
		"system:crypto.3",
	}
} else when ODIN_OS == .Windows {
	foreign import verifylib {
		"system:libssl.lib",
		"system:libcrypto.lib",
	}
} else {
	foreign import verifylib {
		"system:ssl",
		"system:crypto",
	}
}

// SSL_VERIFY_PEER makes the handshake verify the peer's certificate chain.
// SSL_VERIFY_NONE (the upstream default) accepts anything and must never be the
// contract's default.
SSL_VERIFY_NONE :: 0x00
SSL_VERIFY_PEER :: 0x01

// The verification verdict for a chain (and, when SSL_set1_host is used, the
// hostname) that verified against the trust store.
X509_V_OK :: 0

foreign verifylib {
	// Require peer verification. callback may be nil to use the built-in verifier.
	SSL_CTX_set_verify :: proc(ctx: ^SSL_CTX, mode: c.int, callback: rawptr) ---
	// Load the operating system's default CA trust store into the context.
	SSL_CTX_set_default_verify_paths :: proc(ctx: ^SSL_CTX) -> c.int ---
	// Load an additional CA anchor (a PEM file and/or a hashed directory); either
	// argument may be nil. Used for pinned/enterprise trust and test fixtures.
	SSL_CTX_load_verify_locations :: proc(ctx: ^SSL_CTX, ca_file: cstring, ca_path: cstring) -> c.int ---
	// Set the DNS name the peer certificate must match (RFC 6125). Once set,
	// SSL_connect fails the handshake on a hostname mismatch — fail-closed.
	SSL_set1_host :: proc(ssl: ^SSL, hostname: cstring) -> c.int ---
	// The post-handshake verification verdict. X509_V_OK (0) means the chain, and
	// the SSL_set1_host name, verified against the trust store.
	SSL_get_verify_result :: proc(ssl: ^SSL) -> c.long ---
}
