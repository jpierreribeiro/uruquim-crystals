# notes — a real PostgreSQL reference application

A small CRUD service built from the Uruquim core and the data Crystals. It reads
like a conventional web app: explicit handlers, explicit SQL, explicit ownership.

## Deploy sequence

Migrations are a **separate deploy step**. The server never migrates on boot.

```sh
# 1. apply migrations with the migration runner
env MIGRATE_DIR=examples/notes/migrations \
    MIGRATE_HOST=127.0.0.1 MIGRATE_PORT=5432 \
    MIGRATE_USER=... MIGRATE_PASSWORD=... MIGRATE_DB=... \
    ./migrate up

# 2. start the server
env NOTES_PORT=8080 \
    NOTES_DB_HOST=127.0.0.1 NOTES_DB_PORT=5432 \
    NOTES_DB_USER=... NOTES_DB_PASSWORD=... NOTES_DB_NAME=... \
    ./notes-server
```

Production connections default to `verify-full` TLS and SCRAM; the plaintext
profile (`NOTES_ALLOW_PLAINTEXT=1`, `NOTES_DB_SSLMODE=disable`) is only for a
local test database.

## Endpoints

| Method | Path | Behaviour |
|---|---|---|
| POST | `/notes` | create; strict JSON, structured validation, `409` on a duplicate slug |
| GET | `/notes/:id` | fetch one; `404` if absent |
| GET | `/notes?limit=&after=` | keyset pagination, stable order on `id` |
| PATCH | `/notes/:id` | three-state update: absent leaves, `null` clears, a value replaces |
| DELETE | `/notes/:id` | delete; `204`, or `404` if absent |
| GET | `/health/live` | liveness; independent of the database |

## What it demonstrates

- explicit `application_init`/`application_destroy`, with the bounded pool in a
  typed `App_State`;
- SQL `NULL` distinct from a value (`body`), surfaced as JSON `null`;
- three-state PATCH parsed from the raw JSON body into `validate.Patch`;
- a bounded pool that fails fast as `503` when saturated, keeping health live;
- a blocked query that does not stall `/health`;
- a query bounded by a deadline and cancelled server-side;
- a clean shutdown that closes the pool.

The pool's `max_conns` stays below the framework's handler-lane capacity so
database saturation never consumes the capacity health and shutdown need.
