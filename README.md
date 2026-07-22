# Uruquim Crystals

First-party optional packages and tools for
[Uruquim](https://github.com/jpierreribeiro/uruquim).

Crystals line the space the core deliberately leaves empty. They are ordinary
Odin packages: explicitly imported, explicitly initialized and owned by the
application. Uruquim never discovers or imports them.

```text
application ──> uruquim:web
application ──> crystals:web/health ──> uruquim:web
uruquim:web ──X──> crystals
```

The first package is intentionally small:

```odin
import health "crystals:web/health"
import web    "uruquim:web"

app := web.app()
defer web.destroy(&app)

routes := health.routes()
defer web.destroy(&routes)
web.mount(&app, "/health", &routes)
```

The application chooses the prefix and owns composition. `health.routes`
returns a detached `web.Router`; it never mutates or retains the App. Mount
copies route storage, so App and Router remain two owners and both are
destroyed exactly once.

## Build

This repository is one Odin collection. Clone Uruquim beside it at the commit
recorded in [COMPATIBILITY.md](COMPATIBILITY.md), then run:

```sh
env URUQUIM_ROOT=/path/to/uruquim bash build/check.sh
```

Applications pass both collections explicitly:

```sh
odin build ./cmd/api \
  -collection:uruquim=./vendor/uruquim \
  -collection:crystals=./vendor/uruquim-crystals
```

No package manager, generator, registry or runtime plugin mechanism is
required.

## Status

Experimental. Linux x86-64 and the pinned Odin/Uruquim revisions are the only
verified combination. Each package owns a ledger, examples, tests, lifecycle
notes and a rollback path.
