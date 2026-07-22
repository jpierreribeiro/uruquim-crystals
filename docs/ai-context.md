# AI context

This is the optional-package repository for Uruquim, not part of `uruquim:web`.

- Import core as `uruquim:*` and this collection as `crystals:*`.
- Never edit the core to make a Crystal possible.
- Never import `uruquim:web/internal` or access `.private`.
- Applications own composition and long-lived services.
- Route packages return detached Routers; applications mount them.
- SQL is explicit; parameters, transactions, migrations and teardown are
  visible. No ORM, Active Record, DI container or automatic migration boot.
- PostgreSQL uses a private, pinned Odin binding over system libpq 16+. Do not
  expose FFI handles or reimplement the wire protocol inside a Crystal.
- Public names are declared in `build/public-api.txt` and checked by the gate.
- The first package has exactly one public symbol: `web/health.routes`.

Phase 6 is frozen (see `docs/phase-6-freeze.md`). The data stack is six packages:
- `db/postgres` — libpq wrapper: `open`/`close`, `execute`/`query`/`query_one`,
  fail-closed `row_*`/`row_opt_*` decoders, bounded `Pool` (`pool_open`/`acquire`/
  `release`/`pool_close`), query deadlines, and transactions (`begin`/`commit`/
  `rollback`/`rollback_if_open`). FFI handles are `rawptr`; never expose `pq.*`.
- `db/migrate` + `cmd/migrate` — fail-closed migration runner (advisory lock,
  checksums, dirty state); never runs at server boot.
- `validate` + `web/validate` — transport-free validation with three-state
  `Patch(T)` and a thin HTTP error-envelope adapter.
- `db/sqlcheck` — optional CI query checker; inspects, never generates.
- `examples/notes` — the reference CRUD application.
Each package runs single-threaded in tests when it shares the database history
table or fixture tables (`-define:ODIN_TEST_THREADS=1`).
