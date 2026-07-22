# WP75 — PostgreSQL wire/error laboratory

**Status: RED corpus committed, 2026-07-22. Tests-only work package under
ADR-C007. The `db/postgres` public surface introduced here is provisional; its
names and signatures freeze as WP76–WP78 implement and justify them.**

WP74 selected a thin Uruquim-owned wrapper over system `libpq` and froze the
production contract before any API design. WP75 turns every security and failure
claim in that contract into committed, RED-under-control evidence, so the
implementation that follows is measured against a fixed target instead of being
allowed to define its own success.

## What ships

- `db/postgres/` — the wrapper's public API **skeleton**: the typed error
  vocabulary (`Error_Kind`, `Error`), the injection-free `Config`/`Ssl_Mode`
  policy, separated-value `Param` constructors, and the connection, execution,
  cursor and fail-closed decoding signatures. Every fallible body returns
  `Error_Kind.Unimplemented`. No green test may accept that sentinel.
- `tests/postgres/wire_lab_test.odin` — the RED corpus. It is written against
  the real contract (typed SQLSTATE kinds, NULL distinct from empty/zero,
  fail-closed decoding, cardinality, timeout/cancellation, connection-loss
  quarantine, bounded fields, closed-connection refusal) and against the pinned
  disposable server. Until WP76+ implement the bodies, each assertion fails with
  the single diagnosable `Unimplemented` reason.
- `experiments/wp75-lab/main.odin` — a raw-libpq laboratory probe. Independent
  of the wrapper, it proves the pinned server actually produces every condition
  the corpus targets.
- `build/check_wp75_controls.sh` — the control, wired into `build/check.sh`.

## RED-under-control

The corpus is RED for exactly one reason, and the control proves it:

1. the laboratory probe demonstrates the real server conditions
   (`23505/23503/23502/23514`, `NULL≠''≠0`, verbatim parameter round-trip,
   `57014` statement-timeout cancellation, `CONNECTION_BAD` after backend
   termination), with a negative control that mutates an expected SQLSTATE and
   must fail — a probe that cannot fail is not evidence;
2. the corpus compiles, runs, and fails; the control asserts the failure output
   carries the `Unimplemented` sentinel, that *every* test is RED, and that no
   crash or compile error is masquerading as RED;
3. a vacuity guard forbids the corpus from asserting on the sentinel and
   requires it to keep covering every typed kind, so it cannot be gutted to pass.

WP76 consumes this corpus and turns execution and decoding green by
implementing, never by weakening an assertion; the control is updated there.
WP77 turns timeout, cancellation and the bounded-field cases green; WP78 covers
transactions. The laboratory-probe evidence is permanent.

## Framing is libpq's, quarantine is ours

Per ADR-C007 the wrapper does not own protocol framing, so "partial / truncated
/ oversized protocol message" is libpq's responsibility. The wrapper's
obligation is narrower and is what the corpus asserts: when libpq reports the
physical connection as lost or uncertain, the wrapper surfaces a typed
`Connection_Lost`, marks the connection broken, and the pool (WP77) never
returns it as healthy. `oversized_field_is_bounded` covers the application-layer
bound the wrapper does own: a single field or result may not grow without limit.

## Provisional public surface

`build/public-api.txt` now carries the `db/postgres` ledger. It is provisional:
signatures may still change as WP76–WP78 implement them, at which point they
freeze. The core `62 + 2` ledger is untouched; no database type enters `web`.
