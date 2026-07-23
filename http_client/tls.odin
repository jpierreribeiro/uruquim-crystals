package http_client

import "base:runtime"
import "core:c"
import "core:net"
import "core:strings"
import openssl "crystals:vendor/odin-http/openssl"

// tls_connect performs the outbound TLS handshake over an already-connected
// socket and — this is the whole point — makes certificate verification an
// inseparable, fail-closed part of it. Under Verify_Full (the default) it:
//
//   1. requires peer verification (SSL_VERIFY_PEER),
//   2. loads the system trust store (and any configured extra CA anchor),
//   3. sends SNI (SSL_set_tlsext_host_name),
//   4. binds the expected DNS name for RFC 6125 hostname checking (SSL_set1_host),
//   5. lets SSL_connect fail the handshake on any verification error, and
//   6. re-checks SSL_get_verify_result == X509_V_OK as belt-and-suspenders.
//
// A self-signed, expired, or wrong-hostname certificate, or a chain that does
// not build to the trust store, makes SSL_connect fail with a non-OK verify
// result, and this returns Tls_Cert_Invalid. It never returns a live SSL for an
// unverified peer.
//
// Insecure_No_Verify (only reachable with allow_insecure_tls) skips steps 1-2
// and 4-6; it exists solely so a test can demonstrate the difference.
@(private)
tls_connect :: proc(
	sock: net.TCP_Socket,
	host: string,
	cfg: Config,
	loc: runtime.Source_Code_Location,
) -> (
	^openssl.SSL,
	^openssl.SSL_CTX,
	Error,
) {
	ctx := openssl.SSL_CTX_new(openssl.TLS_client_method())
	if ctx == nil {
		return nil, nil, err(.Tls_Failed, "http_client.tls", loc, "context")
	}

	verify := cfg.tls == .Verify_Full
	if verify {
		openssl.SSL_CTX_set_verify(ctx, openssl.SSL_VERIFY_PEER, nil)
		if openssl.SSL_CTX_set_default_verify_paths(ctx) != 1 {
			openssl.SSL_CTX_free(ctx)
			return nil, nil, err(.Tls_Failed, "http_client.tls", loc, "trust store")
		}
		if cfg.tls_ca_file != "" {
			cca := strings.clone_to_cstring(cfg.tls_ca_file)
			defer delete(cca)
			if openssl.SSL_CTX_load_verify_locations(ctx, cca, nil) != 1 {
				openssl.SSL_CTX_free(ctx)
				return nil, nil, err(.Tls_Failed, "http_client.tls", loc, "ca anchor")
			}
		}
	}

	ssl := openssl.SSL_new(ctx)
	if ssl == nil {
		openssl.SSL_CTX_free(ctx)
		return nil, nil, err(.Tls_Failed, "http_client.tls", loc, "ssl")
	}
	openssl.SSL_set_fd(ssl, c.int(sock))

	chost := strings.clone_to_cstring(host)
	defer delete(chost)
	// SNI: many origins select a certificate by the requested name.
	openssl.SSL_set_tlsext_host_name(ssl, chost)
	if verify {
		// Bind the name the peer certificate must match; SSL_connect then fails
		// closed on a hostname mismatch even when the chain is otherwise trusted.
		openssl.SSL_set1_host(ssl, chost)
	}

	ret := openssl.SSL_connect(ssl)
	if ret != 1 {
		vr := openssl.SSL_get_verify_result(ssl)
		openssl.SSL_free(ssl)
		openssl.SSL_CTX_free(ctx)
		if verify && vr != openssl.X509_V_OK {
			return nil, nil, err(.Tls_Cert_Invalid, "http_client.tls", loc, "verify")
		}
		return nil, nil, err(.Tls_Failed, "http_client.tls", loc, "handshake")
	}

	// Even on a "successful" handshake, refuse unless the verdict is clean.
	if verify {
		vr := openssl.SSL_get_verify_result(ssl)
		if vr != openssl.X509_V_OK {
			openssl.SSL_free(ssl)
			openssl.SSL_CTX_free(ctx)
			return nil, nil, err(.Tls_Cert_Invalid, "http_client.tls", loc, "verify")
		}
	}

	return ssl, ctx, Error{}
}

@(private)
ssl_write_all :: proc(ssl: ^openssl.SSL, buf: []byte) -> bool {
	remaining := len(buf)
	for remaining > 0 {
		off := len(buf) - remaining
		ret := openssl.SSL_write(ssl, raw_data(buf[off:]), c.int(remaining))
		if ret <= 0 {
			return false
		}
		remaining -= int(ret)
	}
	return true
}

// destroy an ssl/ctx pair explicitly (used on the send-failure path before a
// Communication is built).
@(private)
tls_free :: proc(ssl: ^openssl.SSL, ctx: ^openssl.SSL_CTX) {
	openssl.SSL_free(ssl)
	openssl.SSL_CTX_free(ctx)
}
