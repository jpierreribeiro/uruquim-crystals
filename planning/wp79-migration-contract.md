# WP79 — migration contract and RED corpus

**Status: RED corpus committed, 2026-07-22. Tests-and-spec work package under
ADR-C008. The `db/migrate` public surface is provisional; WP80 freezes it by
implementing the runner.**

## What a migration is

A migration is an immutable, ordered unit of schema change loaded from disk as
`<id>_<name>.up.sql` with an optional `<id>_<name>.down.sql`. The `id` is a
positive integer that orders the migrations; two migrations may not share an id.
The checksum is the SHA-256 of the up SQL; a change to an already-applied
migration is a refusal, never a silent re-run. A first-line `-- uruquim:no_transaction`
directive opts a migration out of the default wrapping transaction, for the
statements PostgreSQL forbids inside one (for example `CREATE INDEX CONCURRENTLY`).

## The fail-closed contract (RED until WP80)

`tests/migrate` commits, RED-under-control against the pinned container, the
assertions WP80 must satisfy:

- `load` orders by id, rejects duplicate ids and bad filenames, reads down files,
  parses the no_transaction directive and computes a checksum per migration;
- `up` acquires a PostgreSQL advisory lock, validates the whole history
  fail-closed, then applies pending migrations one at a time — each in its own
  transaction unless `no_transaction` — and records id, name, checksum,
  timestamp, duration and tool version;
- `up` is idempotent: a second run applies nothing;
- a `dry_run` reports the plan and applies nothing;
- an applied migration whose file changed is refused with `Checksum_Mismatch`
  before any new DDL;
- a failing migration rolls back (in transactional mode) and is recorded dirty;
  a later run refuses the `Dirty_State` instead of ever reporting the database
  clean;
- `status` reports one row per known id with its state and, for applied rows, the
  tool version and timing.

The advisory-lock laboratory probe (`experiments/wp79-lock`) proves independently
that PostgreSQL gives the mutual exclusion the two-runner safety relies on: a
second connection cannot take a lock the first still holds, and can once it is
released. WP80 adds a real two-process concurrency control.

## Invariants carried forward

- the HTTP server never applies migrations: `web.serve` has no migration path;
- destructive migration tests target only the dedicated disposable database;
- `down` exists but is never presented as guaranteed data recovery;
- deploys with mixed application versions are the application's compatibility
  responsibility, documented at freeze.

## Provisional surface

`build/public-api.txt` now carries the `db/migrate` ledger. It is provisional
until WP80 implements and freezes it. The core `62 + 2` ledger is untouched; no
migration type enters `web`.
