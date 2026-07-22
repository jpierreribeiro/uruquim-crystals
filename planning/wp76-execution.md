# WP76 — PostgreSQL execution and row decoding

**Status: GREEN, 2026-07-22. Implements the db/postgres wrapper bodies that turn
the WP75 execution/decoding corpus green. The public surface introduced by WP75
is now frozen for the connection, execution and decoding APIs; the pool (WP77)
and transactions (WP78) still extend it.**

## What ships

The `db/postgres` wrapper is now real over the vendored libpq binding:

- `open`/`close`/`ping` — connect through libpq keyword/value arrays (never a
  concatenated DSN), refuse a non-thread-safe libpq, pin `require_auth=scram-sha-256`
  so a server cannot downgrade the password mechanism, require channel binding
  whenever TLS verification is active, and refuse plaintext unless the config
  explicitly opts in. Connection failures are classified (auth / TLS / connect)
  from libpq's message, which is inspected but never stored.
- `execute`/`query`/`query_one` — the extended query protocol with positional
  parameters bound separately from the SQL text. There is no interpolation entry
  point. `query_one` enforces exactly-one cardinality.
- typed errors — SQLSTATE mapped to the frozen `Error_Kind` vocabulary
  (integrity class 23, concurrency class 40, connection class 08), with SQLSTATE,
  a safe constraint/column name, the caller's operation label and
  `#caller_location` preserved. The raw human message never enters the Error.
- fail-closed decoding — `row_i64/i32/f64/bool/text/bytes` and their `row_opt_*`
  siblings check the column OID and value: a SQL NULL into a non-optional
  destination is `Decode_Null`, a wrong type is `Decode_Type_Mismatch`, an
  out-of-range integer is `Decode_Overflow`, a bad column is `Decode_Shape`.
  Nothing is left as a silent zero. NULL, empty and zero stay distinct.
- connection-loss quarantine — a command that leaves the physical connection
  uncertain marks the Conn broken so the pool (WP77) can discard it.

The FFI handles live on `Conn`/`Rows` as `rawptr`; the binding is imported only
in private helpers. The gate proves no `pq.*` type reaches the public surface.

## One bug worth recording

The first cut of the transient-encoding arena returned the arena by value
together with an allocator bound to the *local* copy inside the helper — a
dangling pointer the moment the helper returned, which corrupted every
subsequent allocation into a hang. The fix is the ordinary Odin discipline: the
caller owns the arena and passes it by pointer, so the allocator binds to a live
address.

## Gate

`build/check_postgres_controls.sh` (renamed from the WP75 control) now proves:
the laboratory probe and its negative control; the execution/decoding corpus
GREEN against the pinned container; a mutation control that breaks the
SQLSTATE→kind map and confirms the corpus catches it; and the backpressure
corpus (`tests/postgres_backpressure`) RED-under-control until WP77 implements
query deadlines and field bounds.
