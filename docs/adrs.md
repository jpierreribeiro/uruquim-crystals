# Crystals architecture decisions

## ADR-C001 — one-way dependency

**ACCEPTED, 2026-07-22 (WP73).** Applications import core and Crystals;
Crystals may import public core packages; core never imports, discovers,
registers or initializes a Crystal. A core change requested by a Crystal is a
failed Crystal design, not an ecosystem exception.

## ADR-C002 — application-owned composition

**ACCEPTED, 2026-07-22 (WP73).** A Route Crystal returns a detached
`web.Router`. It does not receive or mutate the application's App. The
application selects prefix, order and middleware and calls `web.mount`. Mount
copies; the caller destroys the source Router and the App destroys its copy.

## ADR-C003 — services are application-owned

**ACCEPTED, 2026-07-22 (WP73).** Pools, clients and caches live in the
application's typed `App_State`. There is no Crystal registry, extension bag,
package-global service or hidden initializer. Creation, readiness and
destruction stay visible in the composition root.

## ADR-C004 — one repository and collection initially

**ACCEPTED, 2026-07-22 (WP73).** First-party Crystals share this repository
and the `crystals:` collection while the ecosystem is small. A package leaves
when native dependencies, license, maintainer, users or release cadence demand
independence. Crystals never live inside the core repository.

## ADR-C005 — compatibility is measured against commits

**ACCEPTED, 2026-07-22 (WP73).** Until stable tags exist, the compatibility
matrix names exact Odin and Uruquim commits and a verified platform. “Latest”
is not a reproducible dependency constraint.

## ADR-C006 — explicit public ledgers and independent gates

**ACCEPTED, 2026-07-22 (WP73).** Each package declares its own exports and
evidence. The repository gate compiles examples and tests, rejects internal
core imports/private access and carries a semantic negative control. Core's
62 + 2 ledger is neither copied nor increased by this repository.

## ADR-C007 — PostgreSQL delegates protocol and security to libpq

**ACCEPTED, 2026-07-22 (WP74).** The PostgreSQL Service Crystal will expose a
small synchronous Odin API over system `libpq` 16 or newer. It will not own a
second implementation of framing, SCRAM, TLS, hostname verification or
protocol cancellation. The raw FFI remains private; applications own bounded
pools through `App_State`; SQL and values remain separate. Reconsider a pure
Odin protocol only when a measured deployment constraint makes libpq
unusable. The four-arm evidence and complete pre-API contract live in
`planning/postgres-driver-selection.md`.

## ADR-C008 — migrations are a separate, fail-closed Tool that never runs at boot

**ACCEPTED, 2026-07-22 (WP79).** Schema migration is a Tool Crystal
(`db/migrate`) with its own executable, never a code path the HTTP server can
reach: `web.serve` has no migration step. The runner composes the `db/postgres`
Service Crystal for its connection, transactions and typed errors — a first-party
Crystal may depend on another first-party Crystal in the same collection while
the core still depends on neither.

The contract is fail-closed. Migration ids are immutable and ordered; an applied
migration whose file content changed is refused by checksum before any new DDL;
a PostgreSQL advisory lock ensures only one runner applies at a time; each
migration runs in its own transaction unless it explicitly opts out with
`no_transaction`; and a failed or uncertain migration is recorded dirty and the
database is never reported clean until an operator resolves it. `down` is offered
but never presented as guaranteed data recovery. The full contract and RED
corpus live in `planning/wp79-migration-contract.md`.

## ADR-C009 — validation is transport-free, with a thin HTTP adapter

**ACCEPTED, 2026-07-22 (WP81).** Domain validation lives in a transport-free
Library Crystal (`validate`) that knows nothing about HTTP: it collects typed
field errors, each a stable rule code plus a field path, with no user value. A
separate Request Crystal (`web/validate`) maps those errors onto the framework's
Phase-6 error envelope; the validation package never learns a status code.

The three-state wire contract is modelled by `Patch(T)` — Absent, Null or Set —
so a create input distinguishes an omitted required field from a set zero, and a
PATCH distinguishes "leave", "clear" and "replace". Validation uses explicit rule
calls rather than struct tags or reflection, so there are no unknown flags or
contradictory annotations to fail closed on. The error set is hard-bounded and
reports truncation. The full contract lives in `planning/wp81-validation.md`.
