# laytan/odin-http client bridge snapshot

| Field | Value |
|---|---|
| Upstream | https://github.com/laytan/odin-http |
| Commit | `112c49b5bcee31308a695cc3f05d156d314a61a6` (`openssl: update bundled libraries to openssl-3.6.2`) |
| Vendored | 2026-07-23 (Phase 7.5 Track A) |
| License | MIT (`LICENSE`) |
| Target ABI | OpenSSL 3.x (`libssl.so.3` / `libcrypto.so.3`), libc sockets |

## Why this is a BRIDGE, not a permanent dependency

This is the outbound-client mirror of the server-side vendoring under **ADR-033**,
whose declared exit is the future `core:net/http` **client** (Jan 2027). It exists
so the `http_client` composition Crystal does not reimplement HTTP/1.1 or TLS from
scratch. When `core:net/http` ships an outbound client, this whole tree — and every
patch below — is deleted and the contract package retargets. Nothing outside
`vendor/odin-http/` and the `http_client` package depends on it.

## What was taken

- The full upstream `http` root package (`*.odin`) — one Odin package. It is taken
  whole and **unmodified** because it is not separable: the client's message layer
  (`client/`) imports `http.url_parse`/`http.URL` (which live in `routing.odin`,
  alongside the server router) and `http.headers_validate` (in `request.odin`).
  A subset does not compile. The server/router/nbio files come along as part of the
  faithful snapshot; the `http_client` contract imports **only** `client` and
  `openssl` from this tree and never starts a server. This duplicates the server
  that ADR-033 already vendors inside core — a recorded, deletable tradeoff taken in
  favour of not reimplementing the HTTP/1.1 message codec.
- `client/client.odin`, `client/communication.odin` — the HTTP/1.1 request
  formatter and response parser (status line, headers, cookies, content-length and
  chunked bodies). **Unmodified.**
- `openssl/openssl.odin`, `openssl/.version` — the OpenSSL FFI binding. The
  `openssl/includes/windows/*.lib` static-library blobs were **omitted** (binary
  artifacts, Windows-only); the crystals target links the system `system:ssl` /
  `system:crypto` on Linux/Darwin. The Windows `foreign import` branch is therefore
  non-functional in this snapshot, which is fine for the Linux/Darwin target.

## Numbered BRIDGE patches

All patches are additive files (the upstream snapshot stays byte-faithful) so each
is auditable on its own and removable with the tree.

1. **`openssl/verify.odin` — certificate-verification FFI (security-critical).**
   Upstream's client calls `SSL_connect` on a default context that performs **no**
   peer verification: a self-signed, expired, or wrong-host certificate is silently
   accepted. This patch adds the FFI the contract uses to make verification an
   inseparable, fail-closed part of every `https` connection: `SSL_CTX_set_verify`
   (peer mode), `SSL_CTX_set_default_verify_paths` (system trust store),
   `SSL_CTX_load_verify_locations` (optional extra CA anchor), `SSL_set1_host`
   (RFC 6125 hostname match), `SSL_get_verify_result` (post-handshake verdict), plus
   the `SSL_VERIFY_PEER` / `X509_V_OK` constants. No crypto is implemented; these are
   declarations over the system libraries. The verification *policy* (which calls,
   in which order, and refusing on any failure) lives in the reviewable contract at
   `http_client/tls.odin`, not in the vendor.

2. **`client/bridge.odin` — expose the message layer to the contract (additive
   file).** `format_request`, `parse_response`, and the `Communication` union are
   `#+private` in `communication.odin`. This patch re-exports them (and
   `parse_endpoint`) under `bridge_*` names and adds `bridge_tcp_comm` /
   `bridge_ssl_comm` constructors so the contract can hand the parser a carrier
   built from a socket it dialed, timed, and verified itself. Visibility only; no
   upstream parsing behaviour is changed.

3. **`client/communication.odin` — free the scanner on the parser's error path
   (inline, one `defer`).** Upstream stores its `bufio.Scanner` on the response
   only at the end, on success; every early error return (a timed-out or reset
   read) leaks the scanner's ~4 KiB buffer — a slow-drip DoS on exactly the
   timeout path the contract exercises. The patch adds
   `defer if err != nil { bufio.scanner_destroy(&scanner) }` right after
   `scanner_init`; on success `err` is nil and ownership passes to `res._body`
   unchanged. This is the one inline edit to an upstream file (marked in place);
   patches 1 and 2 are additive files.

The upstream `client.request` entry point is deliberately **not** used by the
contract: it dials without a connect timeout, reads without a request deadline,
has no bounded pool or drain cancellation, and — most importantly — does no
certificate verification. The contract owns all of that.
