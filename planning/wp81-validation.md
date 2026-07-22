# WP81 — validation, optionality and PATCH semantics

**Status: GREEN, 2026-07-22. A transport-free validation Library Crystal and a
thin HTTP adapter, under ADR-C009.**

## The three states a zero value cannot express

`validate.Patch(T)` carries one of three intents the wire distinguishes and a
zero value cannot:

- **Absent** — the field was not present. In a create input that means a required
  field was omitted; it is also the zero value, so a freshly decoded struct
  starts every field Absent until the decoder marks the ones the body carried.
- **Null** — the field was present as JSON `null`. In a PATCH that means "clear".
- **Set** — the field was present with a value. An explicit zero is Set, not
  Absent.

`patch_absent`/`patch_null`/`patch_set` construct them; `patch_is_*` and
`patch_get` read them. This is the ORM-free justification for a `Patch` type: the
three-state contract, not convenience.

## Transport-free validation

`validate` collects `Field_Error{path, code}` values through explicit rule calls
— `require_present`, `deny_null`, `not_empty`, `string_length`, `int_range`,
`one_of` — each recording a stable rule code (`required`, `too_short`,
`above_max`, …) and a field path. It holds no user value, so logging an error set
leaks nothing. There are no struct tags and no reflection, so there are no unknown
flags or contradictory nullable declarations to fail closed on; the rules are
ordinary calls. The error set is hard-bounded (`DEFAULT_MAX_ERRORS`) and reports
`truncated` when a hostile or broken input overruns it, so it can never grow
without limit.

## The thin HTTP adapter

`web/validate` is the only piece that knows about HTTP. `respond` maps a set of
field errors onto the framework's Phase-6 error envelope — the WP68
`{"error":{"code","message"}}` shape extended with a `fields` array — as a `400`
with top code `invalid_field`, matching WP68's classification for a value that
fails a declared rule. `respond_if_invalid(ctx, &v)` writes the envelope and
returns true when the validator holds errors, so a handler reads:

```odin
if vh.respond_if_invalid(ctx, &v) { return }
```

The validation package never learns a status code; the adapter never learns a
domain rule. The envelope is marshalled from a struct, so paths and codes are
escaped by the framework, and it carries no user value.

## Gate

`build/check.sh` compiles both packages, verifies their ledgers, runs the
transport-free corpus (6 cases) and the adapter corpus (2 cases, driven through
`web.test_request`), and a mutation control that disables `require_present` and
confirms the adapter suite catches the missing "required" error.
