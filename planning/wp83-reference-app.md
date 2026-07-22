# WP83 — real PostgreSQL reference application

**Status: GREEN, 2026-07-22. The design test passed.**

`examples/notes` is a deployable CRUD service assembled from the core `web`
framework and every data Crystal. It is the design test for Phase 6: if the APIs
did not compose ergonomically, this application would need escape hatches, hidden
globals or more boilerplate than the joy-of-programming goal permits. It does not
— the handlers read like a conventional web app.

## What it proves at the application boundary

The integration corpus (`tests/notes`, 10 cases, driven over the in-memory
transport against the pinned PostgreSQL server) demonstrates:

- explicit `application_init`/`application_destroy`, the bounded pool in a typed
  `App_State`, and migrations as a separate deploy step (the server never
  migrates on boot);
- create / read / update / delete;
- strict JSON with the framework's unknown-field rejection, and structured
  validation errors through the `web/validate` envelope;
- SQL `NULL` distinct from a value, surfaced as JSON `null`;
- three-state PATCH — an absent field is left, `null` clears, a value replaces —
  parsed from the raw body into `validate.Patch` and applied by one explicit
  `CASE WHEN` statement, no dynamic SQL;
- a unique-constraint conflict mapped to `409`;
- keyset pagination with a stable total order on the primary key;
- a bounded pool that fails fast as `503` when saturated;
- a deliberately blocked query that does not stall `/health` (a real second
  thread holds a connection in `pg_sleep` while health answers in under 250 ms);
- a query bounded by a deadline and cancelled server-side (`Timeout`);
- a graceful shutdown that closes the pool and then refuses new borrows.

## Conventional by construction

The data API uses `insert`/`query`/`execute`/`begin`/`commit`/`acquire`/`release`
and ordinary handler signatures. There is no mythology and no framework-specific
vocabulary in the fundamental path. A user arriving from Gin reads it directly.

## Gate

`build/check_notes_controls.sh` builds the deployable server executable, runs the
integration corpus GREEN, and adds a mutation control that breaks the three-state
PATCH (treating an absent field as present) and confirms the corpus catches the
resulting data loss.
