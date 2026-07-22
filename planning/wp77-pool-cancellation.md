# WP77 — bounded pool, query timeout and cancellation

**Status: GREEN, 2026-07-22. Adds the bounded pool, query deadlines with
server-confirmed cancellation, and result bounds. Turns the WP75 backpressure
cases green and freezes the pool public surface.**

## Cancellation is confirmed, not merely dispatched

A per-query `Query_Opts.deadline_ms` starts a watchdog thread that, on expiry,
calls `PQcancel` through a read-only `PGcancel` object — the one cross-thread use
libpq permits. Dispatching the cancel is not success: `execute`/`query` inspect
the result and only report `Timeout` when the server confirms the interruption
with SQLSTATE `57014`. Any other outcome after a dispatched cancel leaves the
connection uncertain, so it is quarantined as broken. A query that finished
cleanly just as the cancel fired returns its result — a late cancel is not a
failure. `Config.statement_timeout_ms` additionally sets a server-side bound
that needs no thread.

## Bounds refuse before exposing

`Query_Opts.max_rows`, `max_field_bytes` and `max_total_bytes` are enforced
before a cursor is handed back: an oversized result is a typed `Result_Too_Large`
rather than an unbounded application value. libpq has already buffered the
server's bytes, so the bound caps what the wrapper will expose and copy, not
libpq's transient buffer; a true streaming cap via single-row mode is a possible
later refinement recorded here, not a silent omission.

## The pool

`Pool` is hard-capped and thread-safe, created by the application in `App_State`:

- `min_conns` open at `pool_open` as a fail-closed readiness check;
- `max_conns` is the hard cap; a slot is reserved before the connect I/O so the
  cap holds even though the lock is released during the blocking connect;
- `acquire` waits only within `acquire_timeout_ms` **and** the bounded
  `max_waiters` set — a saturated pool returns a typed `Pool_Exhausted`, never an
  unbounded wait or waiter queue;
- a broken or lifetime-expired connection is discarded on release or acquire and
  never returned as healthy;
- `max_idle`, `max_lifetime_ms` and `max_idle_time_ms` recycle connections;
- `pool_close` rejects new borrows, closes idle connections now, and closes
  borrowed ones as their holders release them;
- `pool_stats` exposes open/idle/in-use/waiter counts with no DSN or SQL.

The canonical deployment keeps `max_conns` below the server's Handler-lane
capacity so database saturation fails fast for database work while health and
shutdown stay live.

## Gate

`build/check_postgres_controls.sh` now runs the execution corpus (21 cases,
including deadline and bounds) and the pool corpus (5 cases) GREEN against the
pinned container, with two mutation controls — a broken SQLSTATE map and a pool
that keeps a broken connection — each proving its green suite can still fail.
