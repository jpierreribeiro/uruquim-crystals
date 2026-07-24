#!/usr/bin/env bash
set -euo pipefail

# http_client Composition Crystal controls (Phase 7.5 Track A: A1 contract + RED,
# A2 plaintext over the vendored bridge, A3 outbound TLS + certificate
# verification).
#
# Evidence, in order:
#
#   1. The http_client package compiles against the pinned core and the vendored
#      odin-http client/openssl bridge.
#   2. The plaintext corpus, GREEN against a self-contained local raw-TCP origin:
#      GET round trip, the bounded pool's typed Pool_Exhausted under saturation,
#      connect and request timeouts, connection refusal, and drain cancellation
#      (A1/A2).
#   3. The TLS certificate-verification corpus, GREEN against REAL OpenSSL peers
#      this script wires up (A3) — the security invariant that a bad certificate
#      MUST REFUSE:
#        - a SELF-SIGNED peer, verified against the system trust store, is
#          refused with Tls_Cert_Invalid;
#        - a peer whose chain is trusted but whose cert is for the WRONG hostname
#          (connected by IP, cert is for DNS:localhost) is refused;
#        - the positive control: a trusted, hostname-matching peer is ACCEPTED
#          with status 200, so the refusals are proven to be verification working
#          and not TLS being broken;
#        - the difference control: the same self-signed peer is accepted only
#          under the explicit, opt-in Insecure_No_Verify.
#
# The fixtures (a CA, a good cert for DNS:localhost signed by it, and a
# self-signed cert) are generated at run time and the two `openssl s_server`
# peers are torn down on exit; nothing is left behind.

CRYSTALS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ODIN_BIN="${URUQUIM_ODIN_BIN:-${URUQUIM_COMPILER:-odin}}"
URUQUIM_ROOT="${URUQUIM_ROOT:-}"

GOOD_PORT="${HC_TLS_GOOD_PORT_OVERRIDE:-55461}"
SELF_PORT="${HC_TLS_SELF_PORT_OVERRIDE:-55462}"

fail() { echo "FAIL: $*" >&2; exit 1; }

test -n "$URUQUIM_ROOT" || fail "URUQUIM_ROOT (the pinned core checkout) is not set"
test -d "$URUQUIM_ROOT" || fail "URUQUIM_ROOT does not exist: $URUQUIM_ROOT"
command -v openssl >/dev/null 2>&1 || fail "the openssl CLI is required for the TLS corpus"

WORK="$(mktemp -d)"
GOOD_PID=""
SELF_PID=""
cleanup() {
  [ -n "$GOOD_PID" ] && kill "$GOOD_PID" >/dev/null 2>&1 || true
  [ -n "$SELF_PID" ] && kill "$SELF_PID" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

COLL=(-collection:uruquim="$URUQUIM_ROOT" -collection:crystals="$CRYSTALS_ROOT")

# --- 1. compile -------------------------------------------------------------
echo "--- http_client compiles against core + bridge ---"
"$ODIN_BIN" check "$CRYSTALS_ROOT/http_client" "${COLL[@]}" -no-entry-point ||
  fail "http_client does not compile"

# --- 2. plaintext corpus (A1/A2) --------------------------------------------
echo "--- http_client plaintext corpus (pool, timeouts, refusal, drain) ---"
"$ODIN_BIN" test "$CRYSTALS_ROOT/tests/http_client" "${COLL[@]}" -out:"$WORK/hc-plain" ||
  fail "the plaintext http_client corpus failed"

# --- 3. TLS fixtures + peers ------------------------------------------------
echo "--- generating TLS fixtures and starting OpenSSL peers ---"
(
  cd "$WORK"
  # A fixture CA.
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt \
    -subj "/CN=uruquim http_client fixture CA" -days 2 >/dev/null 2>&1
  # A good cert for DNS:localhost, signed by the fixture CA.
  openssl req -newkey rsa:2048 -nodes -keyout good.key -out good.csr \
    -subj "/CN=localhost" >/dev/null 2>&1
  openssl x509 -req -in good.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out good.crt \
    -days 2 -extfile <(printf "subjectAltName=DNS:localhost") >/dev/null 2>&1
  # A self-signed cert (its own issuer).
  openssl req -x509 -newkey rsa:2048 -nodes -keyout self.key -out self.crt \
    -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" -days 2 >/dev/null 2>&1
) || fail "could not generate the TLS fixtures"

openssl s_server -accept "$GOOD_PORT" -cert "$WORK/good.crt" -key "$WORK/good.key" -www -quiet >/dev/null 2>&1 &
GOOD_PID=$!
openssl s_server -accept "$SELF_PORT" -cert "$WORK/self.crt" -key "$WORK/self.key" -www -quiet >/dev/null 2>&1 &
SELF_PID=$!

# Wait until both peers accept a TLS connection.
for p in "$GOOD_PORT" "$SELF_PORT"; do
  ready=""
  for _ in $(seq 1 50); do
    if openssl s_client -connect "localhost:$p" </dev/null >/dev/null 2>&1; then ready=1; break; fi
    sleep 0.1
  done
  test -n "$ready" || fail "the OpenSSL peer on port $p never came up"
done

# --- 4. TLS certificate-verification corpus (A3) ----------------------------
echo "--- http_client TLS verification corpus (self-signed/wrong-host refuse, good accepts) ---"
env HC_TLS_GOOD_PORT="$GOOD_PORT" HC_TLS_SELF_PORT="$SELF_PORT" HC_TLS_CA="$WORK/ca.crt" \
  "$ODIN_BIN" test "$CRYSTALS_ROOT/tests/http_client_tls" "${COLL[@]}" -out:"$WORK/hc-tls" ||
  fail "the TLS certificate-verification corpus failed"

echo "PASS: http_client controls (plaintext + TLS certificate verification)"
