# WP80 — migration runner

**Status: GREEN, 2026-07-22. Implements the WP79 contract as a library plus a
separate `migrate` executable, and freezes the `db/migrate` surface.**

## What ships

- `db/migrate` bodies: `load` parses, orders, checksums and attaches down files;
  `open` connects and ensures the history table; `status` reports state fail-closed;
  `up` locks, validates and applies; `down` reverts; `destroy_migrations`/
  `destroy_plan` free what the library allocated.
- `cmd/migrate`: the deploy-time executable (`up`, `dry-run`, `status`, `down`),
  configured from the environment, exiting non-zero on every refusal so a deploy
  step fails loudly. It is a separate program; no HTTP server links it.
- `db/postgres` gains `exec_script`: a trusted multi-statement DDL runner over the
  simple query protocol, with no parameters. A migration file legitimately holds
  several statements; parameter separation stays with `execute`/`query`.

## Fail-closed, and proven so

- Each pending migration applies in its own transaction (unless `no_transaction`);
  a failure rolls back and records a dirty marker outside the transaction, so a
  second run refuses `Dirty_State` and the database is never reported clean while
  uncertain. A `no_transaction` failure is likewise recorded dirty.
- An applied migration whose file changed is refused with `Checksum_Mismatch`
  before any new DDL.
- A PostgreSQL advisory lock serializes runners. The two-process control proves
  it: two `migrate up` executables race for the same migration, the lock lets
  exactly one apply while the other is refused, and the migration is recorded
  exactly once — no duplicate-key crash. `open` tolerates the one pre-lock race
  PostgreSQL has, the non-atomic `CREATE TABLE IF NOT EXISTS`, by accepting the
  duplicate-table/duplicate-key SQLSTATE from a concurrent creation.

No `force` command ships. Recovery from a dirty state is a documented operator
procedure requiring explicit database inspection, recorded at freeze.

## Gate

`build/check_migrate_controls.sh` now runs the advisory-lock probe, the contract
corpus GREEN (single-threaded, since it shares the history table and lock), the
two-process serialization control, and a mutation control that disables the
dirty-state refusal and confirms the corpus catches it.
