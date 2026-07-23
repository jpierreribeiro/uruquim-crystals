// http_client TLS certificate-verification corpus — the security invariant.
//
// A bad certificate MUST REFUSE. These tests connect to real OpenSSL peers
// (openssl s_server) wired by build/check_http_client_controls.sh, which passes
// the peer ports and the fixture CA through the environment:
//
//   HC_TLS_SELF_PORT  — an s_server presenting a SELF-SIGNED cert
//   HC_TLS_GOOD_PORT  — an s_server presenting a cert for DNS:localhost, signed
//                       by the fixture CA
//   HC_TLS_CA         — the fixture CA PEM (a trust anchor for the good peer)
//
// Without the environment the tests are a no-op (they skip), so the suite is
// safe to compile and list in the gate even off the harness.
package test_http_client_tls

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import hc "crystals:http_client"

@(private)
env :: proc(key: string) -> (string, bool) {
	v := os.get_env(key, context.temp_allocator)
	if v == "" {
		return "", false
	}
	return v, true
}

@(private)
u :: proc(scheme, host, port: string) -> string {
	return strings.concatenate({scheme, "://", host, ":", port, "/"})
}

// The headline proof: a self-signed peer, verified against the system trust
// store, is REFUSED — not accepted, not a Response. Tls_Cert_Invalid.
@(test)
test_selfsigned_refuses :: proc(t: ^testing.T) {
	port, ok := env("HC_TLS_SELF_PORT")
	if !ok {
		log.info("HC_TLS_SELF_PORT unset; skipping")
		return
	}
	context.logger = log.nil_logger()

	c, _ := hc.open(hc.Config{max_conns = 2, connect_timeout_ms = 4000, request_timeout_ms = 4000})
	defer hc.close(&c)

	target := u("https", "localhost", port)
	defer delete(target)
	resp, e := hc.get(&c, target)
	defer hc.response_destroy(&resp)

	testing.expectf(
		t,
		e.kind == hc.Error_Kind.Tls_Cert_Invalid,
		"self-signed cert must REFUSE with Tls_Cert_Invalid, got %v (status %d)",
		e.kind,
		resp.status,
	)
}

// A cert that verifies to a trusted CA but is for the WRONG hostname is REFUSED.
// The good peer's cert covers DNS:localhost only; connecting by IP (127.0.0.1),
// which the cert does not cover, must fail hostname verification even though the
// chain is trusted.
@(test)
test_wrong_hostname_refuses :: proc(t: ^testing.T) {
	port, ok := env("HC_TLS_GOOD_PORT")
	ca, ok2 := env("HC_TLS_CA")
	if !ok || !ok2 {
		log.info("HC_TLS_GOOD_PORT/HC_TLS_CA unset; skipping")
		return
	}
	context.logger = log.nil_logger()

	c, _ := hc.open(
		hc.Config{max_conns = 2, connect_timeout_ms = 4000, request_timeout_ms = 4000, tls_ca_file = ca},
	)
	defer hc.close(&c)

	target := u("https", "127.0.0.1", port) // cert is for localhost, not 127.0.0.1
	defer delete(target)
	resp, e := hc.get(&c, target)
	defer hc.response_destroy(&resp)

	testing.expectf(
		t,
		e.kind == hc.Error_Kind.Tls_Cert_Invalid,
		"wrong-hostname cert must REFUSE with Tls_Cert_Invalid, got %v (status %d)",
		e.kind,
		resp.status,
	)
}

// The positive control: a cert whose chain AND hostname verify is ACCEPTED, so
// the refusals above are proven to be verification working, not TLS being broken.
@(test)
test_trusted_and_matching_accepts :: proc(t: ^testing.T) {
	port, ok := env("HC_TLS_GOOD_PORT")
	ca, ok2 := env("HC_TLS_CA")
	if !ok || !ok2 {
		log.info("HC_TLS_GOOD_PORT/HC_TLS_CA unset; skipping")
		return
	}

	c, _ := hc.open(
		hc.Config{max_conns = 2, connect_timeout_ms = 4000, request_timeout_ms = 4000, tls_ca_file = ca},
	)
	defer hc.close(&c)

	target := u("https", "localhost", port)
	defer delete(target)
	resp, e := hc.get(&c, target)
	defer hc.response_destroy(&resp)

	testing.expectf(t, !hc.is_err(e), "trusted+matching cert must connect, got %v", e.kind)
	testing.expect_value(t, resp.status, 200)
}

// The difference proof: the SAME self-signed peer that is refused under
// Verify_Full is ACCEPTED under the explicit, opt-in Insecure_No_Verify — so the
// refusal is verification, and disabling it is the only way through. This mode
// requires allow_insecure_tls and exists solely for this contrast.
@(test)
test_insecure_mode_accepts_selfsigned :: proc(t: ^testing.T) {
	port, ok := env("HC_TLS_SELF_PORT")
	if !ok {
		log.info("HC_TLS_SELF_PORT unset; skipping")
		return
	}

	c, _ := hc.open(
		hc.Config {
			max_conns = 2,
			connect_timeout_ms = 4000,
			request_timeout_ms = 4000,
			tls = .Insecure_No_Verify,
			allow_insecure_tls = true,
		},
	)
	defer hc.close(&c)

	target := u("https", "localhost", port)
	defer delete(target)
	resp, e := hc.get(&c, target)
	defer hc.response_destroy(&resp)

	testing.expectf(t, !hc.is_err(e), "insecure mode must accept the self-signed peer, got %v", e.kind)
	testing.expect_value(t, resp.status, 200)
}
