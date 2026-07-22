# WP74 — PostgreSQL driver selection and frozen contract

**Status: ACCEPTED, 2026-07-22. Selected arm: a thin Uruquim-owned wrapper
over system `libpq` 16 or newer, using the pinned MIT Odin binding. No public Crystal
API is frozen by this document.**

## Decision

The data Crystal will not implement PostgreSQL's wire, TLS or authentication
protocol. It will own a small Odin API and delegate those mechanisms to
PostgreSQL's client library. `pq.Conn`, `pq.Result`, cstrings and numeric OIDs
remain private implementation details.

This is not “C instead of Odin” as a value judgment. It is choosing where the
security boundary already has mature ownership. The joy-of-programming result
is still an ordinary synchronous Odin call; the application does not handle
FFI, connection strings, result cleanup or C memory.

## Four-arm matrix

| Arm | Evidence | Verdict |
|---|---|---|
| existing maintained Odin driver | Ecosystem search found `laytan/odin-postgresql`, but it is complete raw `libpq` bindings, not a lifecycle/pool/row driver. No maintained standalone Odin driver met the contract. | Not independently available; use the binding under arm 3. |
| extract a pure-Odin implementation | Gjallarhorn commit `1fd039d` has SCRAM-SHA-256, extended Parse/Bind/Describe/Execute, SQLSTATE and optional OpenSSL verification. Its `pg_read_msg` allocates the server-declared length with no cap; row readers advance without bounds checks; `BackendKeyData` is explicitly ignored, so PostgreSQL cancellation is impossible; pool acquire waits without a bound; DB tests skip as success when PostgreSQL is absent. It is also embedded in one full-stack package. | Valuable prior art, not an auditable production dependency for this phase. |
| wrap `libpq` | PostgreSQL 16 provides SCRAM, channel binding, `verify-full`, client certificates, parameter separation, thread-safe distinct connections, result metadata and cross-thread `PQcancel`. The verified local `libpq` is 18; the minimum is 16, and the FFI tag is 16.9 and MIT. | **SELECTED.** Small wrapper, largest inherited test/security base. |
| implement protocol v3 locally | Feasible, as Gjallarhorn proves, but honest parity requires framed parser hardening, TLS/hostname/CA/client-cert policy, SCRAM and channel binding, key capture/cancel race, COPY/notice/error resynchronization and version tests. | Rejected while libpq satisfies the contract. Reopen only for a measured deployment constraint. |

## Production contract frozen before API design

### Security

- Production TCP defaults to certificate and hostname verification
  (`sslmode=verify-full`, system or explicit CA). There is no “prefer” default
  and no silent plaintext fallback.
- The accepted password mechanism is SCRAM-SHA-256. libpq 16's `require_auth`
  is set so a server cannot downgrade to MD5 or cleartext. Channel binding is
  required for verified TLS and disabled only for the explicit local plaintext
  test profile.
- Client certificate/key paths are optional explicit configuration. Secrets,
  DSNs, SQL parameter values and raw server messages never enter diagnostics.
- Parameter values always cross `PQexecParams`/`PQsendQueryParams`, separate
  from SQL. The wrapper has no interpolation escape hatch.

### Ownership and threading

- The application creates and destroys a bounded Pool in `App_State`.
- One borrowed connection has one calling thread. No two threads touch one
  `PGconn` concurrently, except a read-only `PGcancel` object used by the
  cancellation thread as libpq explicitly permits.
- Startup refuses when `PQisthreadsafe() != 1`.
- Every `PGresult`, `PGcancel` and failed `PGconn` is released exactly once.
  Public values own Odin memory only.

### Bounds and cancellation

- Pool open/idle counts, waiter count, acquire deadline, query deadline,
  maximum rows, columns, field bytes and total decoded result bytes are hard
  limits validated before serving.
- Query retrieval uses libpq single-row/chunked result mode so the wrapper can
  reject a result before accumulating an unbounded application value.
- Deadline sends `PQcancel` from a separate thread. Successful dispatch is not
  reported as successful cancellation: the query must finish with the expected
  cancellation SQLSTATE, or its connection is discarded as uncertain.
- Closing a pool rejects new borrows, wakes bounded waiters, and never returns
  a broken or transaction-uncertain connection to the available set.

### Errors and decoding

- No fallible operation returns only `bool`. Errors carry a stable kind,
  SQLSTATE, safe constraint/column metadata, query name and `#caller_location`.
- Human server messages are diagnostic detail, never HTTP policy and never a
  stable application discriminator.
- `NULL`, empty and zero remain distinct. Type mismatch, overflow, malformed
  UTF-8 where text is promised and column-shape mismatch are errors; no field
  silently retains its zero value.

## Reproducible harness

Integration tests own container `uruquim-crystals-pg16`, database
`uruquim_crystals_test`, loopback port 55434 and image
`postgres:16-alpine@sha256:20edbde7749f822887a1a022ad526fde0a47d6b2be9a8364433605cf65099416`.
They refuse an arbitrary developer DSN for destructive cases.

The WP74 prototype proved on 2026-07-22 that libpq 18 reports thread safety,
connects with SCRAM to PostgreSQL 16.13 in that image, resolves the corrected
`PQparameterStatus` binding and executes the extended query protocol. WP75
turns every security and failure claim above into a RED or negative-control
case before the wrapper surface is implemented.

## Primary references

- https://www.postgresql.org/docs/16/libpq-threading.html
- https://www.postgresql.org/docs/16/libpq-connect.html
- https://www.postgresql.org/docs/16/libpq-exec.html
- https://www.postgresql.org/docs/16/libpq-cancel.html
- https://www.postgresql.org/docs/16/protocol-flow.html
