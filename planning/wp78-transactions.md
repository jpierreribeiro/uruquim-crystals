# WP78 — explicit transactions

**Status: GREEN, 2026-07-22. One canonical transaction pattern on one borrowed
connection, held until a known terminal state.**

## The pattern

```odin
tx, err := postgres.begin(&pool, options)
if postgres.is_err(err) { /* ... */ }
defer postgres.rollback_if_open(&tx)

_, err = postgres.tx_execute(&tx, "users.insert", sql, params)
// ...

err = postgres.commit(&tx)
```

`begin` borrows one connection and opens the transaction on it; the connection is
not returned to the pool until the transaction reaches a terminal state, so a
half-finished transaction can never leak back into the available set. On a
failed `begin` the connection is returned immediately and no partial transaction
holds it.

## Lifecycle rules

- `tx_execute`/`tx_query`/`tx_query_one` run on the transaction's single
  connection. A server error moves the transaction to `Failed`; further work is
  refused with a typed error until rollback, matching PostgreSQL's aborted-block
  semantics.
- `commit` on an open transaction commits; on an already-committed transaction it
  is an idempotent success; on a `Failed` transaction it rolls back and reports
  the failure; on a rolled-back transaction it is refused.
- `rollback` discards the transaction; a second rollback is an idempotent
  success; rolling back a committed transaction is refused.
- `rollback_if_open` is the canonical `defer` guard, safe to call
  unconditionally.
- A broken or transaction-uncertain connection is never committed and never
  returned to the pool as healthy; it is released and the pool quarantines it.
- Isolation (`Read_Committed`/`Repeatable_Read`/`Serializable`), `read_only` and
  `deferrable` are set on the `BEGIN` from fixed clauses — no user text is
  interpolated. A commit-time serialization failure surfaces its SQLSTATE.

Nesting is refused by construction: `begin` takes a pool, not a transaction, so
there is no nested-transaction API. Savepoints are intentionally not offered in
this first surface.

## Gate

`build/check_postgres_controls.sh` runs the transaction corpus (7 cases: commit
persists, rollback discards, one-connection identity, error-aborts-then-recovers,
commit idempotence and terminal enforcement, read-only refusal, serializable
isolation) GREEN, plus a mutation control that turns rollback into a no-op and
confirms the corpus catches the leak.
