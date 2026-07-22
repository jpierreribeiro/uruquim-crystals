# Phase 6 freeze — the data stack

**Status: FROZEN, 2026-07-22.** This document freezes the Uruquim Crystals data
stack (WP73–WP83). The concurrency half of Phase 6 (WP66–WP72) froze in the core
repository at core `f51fc127` (WP72, "freeze bounded concurrent serving"); this
freeze covers everything the Crystals ecosystem delivers on top of it.

The freeze gate is `build/check.sh`. It is green: every package compiles, every
ledger matches the compiler inventory, every laboratory probe and integration
corpus passes against the pinned server, and every mutation control fails when
its target is broken.

## Pinned environment

| Component | Value |
|---|---|
| Odin | `dev-2026-07a`, commit `819fdc7` |
| Uruquim core | `f51fc127f4c7f937069b867d295e271c40e13ff5` (Phase 5 frozen + WP66–72) |
| PostgreSQL harness | `postgres:16-alpine`, pinned by digest |
| libpq ABI | `libpq.so.5`, version 16 or newer (verified 18) |
| Platform | Linux x86-64 |

## Public ledger — 6 packages, 125 symbols

The core `62 + 2` ledger is untouched; no database, migration, validation or
checker type entered `web`. Each Crystal owns its literal ledger in
`build/public-api.txt`, verified per package by the gate.

| Package | Kind | Symbols | Purpose |
|---|---|---|---|
| `web/health` | Route | 1 | detached liveness route (WP73) |
| `db/postgres` | Service | 64 | libpq wrapper: connection, execution, fail-closed decoding, bounded pool, cancellation, transactions (WP75–78, WP80) |
| `db/migrate` | Tool | 16 | fail-closed migration runner (WP79–80) |
| `validate` | Library | 32 | transport-free validation and three-state `Patch` (WP81) |
| `web/validate` | Request | 3 | validation → HTTP error envelope adapter (WP81) |
| `db/sqlcheck` | Tool | 9 | optional CI query checker (WP82) |

## Claims, capacities and lifetimes

**PostgreSQL (`db/postgres`).**
- Security: production TCP defaults to `verify-full` + SCRAM-SHA-256, `require_auth`
  pinned so the server cannot downgrade; channel binding required under TLS
  verification; plaintext refused unless explicitly opted in. FFI types never
  cross the public surface (gate-enforced).
- Errors: no fallible operation returns only `bool`; every error carries a typed
  kind, SQLSTATE, a safe constraint/column name, an operation label and a source
  location; raw SQL, values, credentials, DSNs and server messages stay out of
  diagnostics. `NULL`, empty and zero are distinct; decode is fail-closed.
- Capacities: the pool has hard `max_conns`, a bounded waiter set (`max_waiters`)
  and a bounded acquire deadline; a saturated pool returns `Pool_Exhausted`, never
  an unbounded wait. Query bounds (`max_rows`, `max_field_bytes`, `max_total_bytes`)
  refuse an oversized result as `Result_Too_Large`.
- Cancellation: a query deadline cancels via `PQcancel`; only a server-confirmed
  `57014` is a `Timeout`, any other post-cancel outcome quarantines the
  connection. A broken or transaction-uncertain connection is never returned to
  the pool as healthy. A transaction holds one connection until a terminal state.
- Lifetimes: `Rows` text/bytes copy into caller memory; `Error.detail` borrows a
  per-connection buffer valid until the next operation; the application owns the
  pool in `App_State`.

**Migrations (`db/migrate`).** Immutable ordered ids; SHA-256 checksums refuse a
changed applied file before new DDL; a PostgreSQL advisory lock serializes
runners (proven with two real processes); each migration is one transaction unless
it opts out; a failure records dirty and the database is never reported clean
while uncertain. The server never migrates on boot. No `force` command ships;
dirty-state recovery is an operator procedure requiring explicit inspection.

**Validation (`validate`, `web/validate`).** `Patch(T)` is Absent / Null / Set;
rules are explicit calls with stable codes and field paths and no user value; the
error set is hard-bounded and reports truncation. The HTTP adapter maps errors to
the `400 invalid_field` envelope without teaching validation about status codes.

**Checker (`db/sqlcheck`).** Prepares each query and inspects inferred metadata;
generates no code; reports a statically unpreparable query as `Unchecked` rather
than falsely certifying it.

## Deliveries and non-deliveries

- **Delivered:** the runtime PostgreSQL data stack, the fail-closed migration
  runner and executable, transport-free validation with a thin HTTP adapter, the
  optional checker (delivered, not refused — ADR-C010), and the real reference
  application demonstrating CRUD, constraints, three-state PATCH, pagination,
  bounded-pool backpressure, blocked-query health liveness, cancellation and
  graceful shutdown.
- **Bounded / deferred, recorded honestly:**
  - result bounds are enforced after libpq buffers the server's bytes; a true
    streaming cap via single-row mode is a possible later refinement, not a silent
    omission (WP77);
  - a query stuck in non-cancellable foreign code cannot be preempted; only a
    server-confirmed cancellation is claimed (inherited from the core concurrency
    limitation);
  - the `sqlcheck` array parser handles the common regtype forms; exotic
    quoted-with-comma type names are out of scope.
- **Refused by design:** ORM, Active Record, lazy loading, automatic associations,
  implicit transactions, `UPDATE`-to-`INSERT` fallback, production auto-migration,
  mandatory code generation, a DI container.

## Future transport replacement

No Crystal names an odin-http type; the data stack depends only on the core public
surface. When the official `core:net/http` adapter lands in core, the Crystals
recompile against the new pinned core commit with no data-stack change; only
`COMPATIBILITY.md` and the gate's `EXPECTED_CORE` move.
