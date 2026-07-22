# WP82 — optional SQL/schema checker

**Status: DELIVERED (not refused), 2026-07-22, under ADR-C010.**

WP82 was allowed to conclude in an evidence-backed refusal if a useful checker
required code generation or metaprogramming. It does not: PostgreSQL 16 exposes
enough through `PREPARE` and `pg_prepared_statements` to build a real checker
that generates nothing.

## What it does

`db/sqlcheck` takes a list of `Check{name, sql, expect_params, expect_results}`
and, against a real migrated database:

1. `PREPARE`s each query (via the simple protocol, so the query's own `$N` are the
   prepared statement's parameters);
2. reads the inferred `parameter_types` and `result_types` from
   `pg_prepared_statements`;
3. classifies each query:
   - **Ok** — prepared, and every declared expectation matched;
   - **Prepare_Failed** — a missing table/column or malformed query (the SQLSTATE
     is the safe detail);
   - **Param_Count_Mismatch** / **Result_Mismatch** — the shape differs from the
     declaration;
   - **Unchecked** — PostgreSQL cannot statically prepare the query (indeterminate
     parameter type `42P18`, unsupported feature `0A000`); it is reported honestly,
     never falsely certified.

`has_failures` ignores `Ok` and `Unchecked`, so a CI wrapper exits non-zero only
on a real problem. The runtime application keeps executing explicit SQL; nothing
here generates code, and using PostgreSQL never requires running the checker.

## Boundaries

- The checker inspects; it does not generate. Generation could be offered later
  as an optional accelerator, never a requirement (ADR-C010).
- Dynamic SQL beyond static preparation is `Unchecked`, not certified.
- It reuses `db/postgres` for the connection and `db/migrate` for schema setup;
  the corpus proves the full workflow — migrate, then check.

## Gate

`build/check_sqlcheck_controls.sh` runs the corpus GREEN against the pinned
container (three cases across all five classifications, `has_failures`, and the
migrate-then-check workflow) and a mutation control that misclassifies a
`Prepare_Failed` as `Ok` and confirms the corpus catches it.
