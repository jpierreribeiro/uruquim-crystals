# Phase 7.5 — Composition Crystals freeze

**Status: FROZEN** (2026-07-23). Track A of Phase 7.5. This freezes the two
composition Crystals that were the Crystals half of Phase 7 and are the entry
condition **E8-7** for Phase 8: `http_client` and `metrics`. Their public
ledgers are pinned in `build/public-api.txt` and enforced by `verify_ledger` in
`build/check.sh`.

## What froze

### `http_client` — outbound HTTP/1.1 with fail-closed TLS (A1–A3)

An outbound client over a vendored `laytan/odin-http` **client + openssl BRIDGE**
(the outbound mirror of the server-side vendoring under ADR-033; declared exit =
the future `core:net/http` client, Jan 2027), wrapped in the contract the BOM
requires:

- a **bounded connection pool** with a typed `Pool_Exhausted` (never unbounded);
- **per-connect and per-request timeouts** under one **deadline budget**;
- **drain cancellation** — a registered socket is shut down and its in-flight
  read unblocked when the client drains;
- **bounded retry** semantics stated as at-least-once (no unbounded queue,
  no thread-per-task);
- **outbound TLS with certificate verification as an inseparable, fail-closed
  part of every `https` connection** — `SSL_VERIFY_PEER`, the system trust store
  (plus an optional CA anchor), SNI, RFC 6125 hostname binding (`SSL_set1_host`),
  a `SSL_connect` that fails closed, and a post-handshake
  `SSL_get_verify_result == X509_V_OK` recheck. `Insecure_No_Verify` is opt-in
  behind `allow_insecure_tls`, present only for the difference control.

**Evidence:** `build/check_http_client_controls.sh` — plaintext corpus (pool
exhaustion, connect/request timeouts, refusal, drain) and a TLS
certificate-verification corpus against real `openssl s_server` peers: a
self-signed peer is **refused**, a trusted-chain-but-wrong-hostname peer is
**refused**, and a trusted-and-matching peer is **accepted** (the positive
control), with the same self-signed peer accepted only under the explicit
insecure mode. A bad certificate fails closed.

Ledger: `http_client` (20 public symbols in `build/public-api.txt`).

### `metrics` — Prometheus exposition over the observer surface (A4)

`web/metrics` renders the core's deliberately-tiny observability surface
(`web.observe` push events + `web.refused_connections()` pull scalar) as one
canonical `text/plain` Prometheus exposition. Counters are derived per closed
`web.Framework_Error` kind, so output is **bounded** by the enum, independent of
traffic. **WP20 redaction is preserved by construction**: the only event datum
read is the closed-enum `kind` — never a route string, a path, or any request
byte — so nothing request-derived can reach the output.

**Evidence:** `tests/metrics` — a triggered framework error is counted by kind,
the exposition structure and the refused-connections scalar are rendered, and
the raw request path is proven absent from the output.

Ledger: `web/metrics` (`install`, `routes`).

## BOM

Both were already classified **CRYSTAL** in `planning/production-service-bom.md`
(§2 outbound: `http_client` + inseparable outbound TLS; §observability:
`metrics`). This freeze is the shipped evidence behind that classification and
satisfies **E8-7**. The deadline-budget item (ABERTO, trigger = "existence of
`http_client`") has had its trigger fire — `http_client` implements the
request/connect/deadline budget — recorded in the BOM.

## The BRIDGE, and its exit

`vendor/odin-http` (the client + openssl trees) is a BRIDGE, deletable whole at
the `core:net/http` outbound-client transition (ADR-033). Nothing outside
`vendor/odin-http/` and the `http_client` package depends on it. See
`vendor/odin-http/VENDOR.md`.
