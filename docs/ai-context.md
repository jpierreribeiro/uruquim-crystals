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
