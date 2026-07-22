#!/usr/bin/env bash
set -euo pipefail

CRYSTALS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_ROOT="${URUQUIM_ROOT:-}"
ODIN_BIN="${URUQUIM_ODIN_BIN:-${URUQUIM_COMPILER:-odin}}"

fail() {
  echo "CRYSTALS-GATE-FAIL: $*" >&2
  exit 1
}

test -d "$URUQUIM_ROOT/web" || fail "set URUQUIM_ROOT to the pinned Uruquim checkout"

EXPECTED_CORE="f51fc127f4c7f937069b867d295e271c40e13ff5"
ACTUAL_CORE="$(git -C "$URUQUIM_ROOT" rev-parse HEAD 2>/dev/null || true)"
test "$ACTUAL_CORE" = "$EXPECTED_CORE" ||
  fail "core commit is $ACTUAL_CORE, expected $EXPECTED_CORE"

TMP="$(mktemp -d -t uruquim-crystals-gate-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# verify_ledger proves that a package's compiler-visible public symbols are
# exactly the symbols declared in build/public-api.txt. A package cannot grow
# or shrink its surface without paying the ledger.
verify_ledger() {
  local pkg="$1"
  local doc_syms ledger_syms
  doc_syms="$("$ODIN_BIN" doc "$CRYSTALS_ROOT/$pkg" -short \
      -collection:uruquim="$URUQUIM_ROOT" \
      -collection:crystals="$CRYSTALS_ROOT" 2>/dev/null \
    | grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*::' \
    | sed -E 's/[[:space:]]*::.*//; s/^[[:space:]]+//' | sort -u)"
  ledger_syms="$(awk -F' \\| ' -v p="$pkg" '$1==p{print $3}' \
    "$CRYSTALS_ROOT/build/public-api.txt" | sort -u)"
  if [ "$doc_syms" != "$ledger_syms" ]; then
    echo "ledger mismatch for $pkg (< ledger, > compiler):" >&2
    diff <(printf '%s\n' "$ledger_syms") <(printf '%s\n' "$doc_syms") >&2 || true
    fail "$pkg exports do not match its ledger"
  fi
}

# --- web/health: the first Route Crystal (WP73) ---

"$ODIN_BIN" check "$CRYSTALS_ROOT/web/health" \
  -no-entry-point \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$CRYSTALS_ROOT"

"$ODIN_BIN" test "$CRYSTALS_ROOT/tests/health" \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$CRYSTALS_ROOT" \
  -out:"$TMP/health-test"

"$ODIN_BIN" build "$CRYSTALS_ROOT/examples/health" \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$CRYSTALS_ROOT" \
  -out:"$TMP/health-example"

verify_ledger web/health

# Semantic negative control: changing the fixed route must make the public
# behaviour test fail. A control that cannot fail is not evidence.
mkdir -p "$TMP/mutant/web/health" "$TMP/mutant/tests/health"
cp "$CRYSTALS_ROOT/web/health/health.odin" "$TMP/mutant/web/health/"
cp "$CRYSTALS_ROOT/tests/health/health_test.odin" "$TMP/mutant/tests/health/"
sed -i 's#"/live"#"/ready"#' "$TMP/mutant/web/health/health.odin"
if "$ODIN_BIN" test "$TMP/mutant/tests/health" \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$TMP/mutant" \
  -out:"$TMP/mutant-test" >/dev/null 2>&1; then
  fail "route mutation unexpectedly passed"
fi

echo "crystals: web/health exports one detached Router constructor"

# --- db/postgres: the PostgreSQL Service Crystal (WP75+) ---

"$ODIN_BIN" check "$CRYSTALS_ROOT/db/postgres" \
  -no-entry-point \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$CRYSTALS_ROOT"

verify_ledger db/postgres

# The raw libpq FFI types must never appear in a public signature or field. The
# wrapper keeps handles as rawptr; the compiler inventory proves nothing leaks.
if "$ODIN_BIN" doc "$CRYSTALS_ROOT/db/postgres" \
    -collection:uruquim="$URUQUIM_ROOT" \
    -collection:crystals="$CRYSTALS_ROOT" 2>/dev/null \
  | grep -qE '\bpq\.(Conn|Result|Cancel|OID|Format|Exec_Status|Connection_Status)\b'; then
  fail "an FFI type escapes the db/postgres public surface"
fi

# --- db/migrate: the migration Tool Crystal (WP79+) ---

"$ODIN_BIN" check "$CRYSTALS_ROOT/db/migrate" \
  -no-entry-point \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$CRYSTALS_ROOT"

verify_ledger db/migrate

# --- validate: transport-free validation Library Crystal (WP81) ---
# --- web/validate: the thin HTTP adapter (WP81) ---

"$ODIN_BIN" check "$CRYSTALS_ROOT/validate" \
  -no-entry-point \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$CRYSTALS_ROOT"
verify_ledger validate

"$ODIN_BIN" check "$CRYSTALS_ROOT/web/validate" \
  -no-entry-point \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$CRYSTALS_ROOT"
verify_ledger web/validate

# --- db/sqlcheck: optional CI query checker (WP82) ---

"$ODIN_BIN" check "$CRYSTALS_ROOT/db/sqlcheck" \
  -no-entry-point \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$CRYSTALS_ROOT"
verify_ledger db/sqlcheck

# --- examples/notes: the real PostgreSQL reference application (WP83) ---

"$ODIN_BIN" check "$CRYSTALS_ROOT/examples/notes" \
  -no-entry-point \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$CRYSTALS_ROOT"

"$ODIN_BIN" test "$CRYSTALS_ROOT/tests/validate" \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$CRYSTALS_ROOT" \
  -out:"$TMP/validate-test"

"$ODIN_BIN" test "$CRYSTALS_ROOT/tests/validate_http" \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$CRYSTALS_ROOT" \
  -out:"$TMP/validate-http-test"

# Semantic negative control: if require_present stops flagging an absent field,
# the adapter test that expects a "required" error must fail. A validation suite
# that cannot fail is not evidence.
mkdir -p "$TMP/vmut/validate"
cp "$CRYSTALS_ROOT/validate/"*.odin "$TMP/vmut/validate/"
mkdir -p "$TMP/vmut/web/validate"
cp "$CRYSTALS_ROOT/web/validate/"*.odin "$TMP/vmut/web/validate/"
sed -i 's/if state == .Absent {/if false {/' "$TMP/vmut/validate/validate.odin"
if "$ODIN_BIN" test "$CRYSTALS_ROOT/tests/validate_http" \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$TMP/vmut" \
  -out:"$TMP/vmut-test" >/dev/null 2>&1; then
  fail "disabled require_present unexpectedly passed; the validation suite is not evidence"
fi

echo "crystals: validate and web/validate ledgers verified and controls sound"

# No shipping Crystal may reach into core internals or private state.
if grep -Rqs 'uruquim:web/internal' "$CRYSTALS_ROOT/web" "$CRYSTALS_ROOT/db" "$CRYSTALS_ROOT/validate"; then
  fail "a Crystal imports core internals"
fi
if grep -RqsE '\.(private)\b' "$CRYSTALS_ROOT/web" "$CRYSTALS_ROOT/db" "$CRYSTALS_ROOT/validate"; then
  fail "a Crystal reaches core private state"
fi

echo "crystals: core dependency is one-way and pinned at $EXPECTED_CORE"
echo "PASS: web/health and db/postgres ledgers verified"

# --- WP74 driver-selection controls and the PostgreSQL Service Crystal ---

env \
  URUQUIM_ODIN_BIN="$ODIN_BIN" \
  URUQUIM_TEST_DATABASE_URL="${URUQUIM_TEST_DATABASE_URL:-}" \
  bash "$CRYSTALS_ROOT/build/check_wp74_controls.sh"

env \
  URUQUIM_ODIN_BIN="$ODIN_BIN" \
  URUQUIM_ROOT="$URUQUIM_ROOT" \
  URUQUIM_TEST_DATABASE_URL="${URUQUIM_TEST_DATABASE_URL:-}" \
  bash "$CRYSTALS_ROOT/build/check_postgres_controls.sh"

env \
  URUQUIM_ODIN_BIN="$ODIN_BIN" \
  URUQUIM_ROOT="$URUQUIM_ROOT" \
  URUQUIM_TEST_DATABASE_URL="${URUQUIM_TEST_DATABASE_URL:-}" \
  bash "$CRYSTALS_ROOT/build/check_migrate_controls.sh"

env \
  URUQUIM_ODIN_BIN="$ODIN_BIN" \
  URUQUIM_ROOT="$URUQUIM_ROOT" \
  URUQUIM_TEST_DATABASE_URL="${URUQUIM_TEST_DATABASE_URL:-}" \
  bash "$CRYSTALS_ROOT/build/check_sqlcheck_controls.sh"

env \
  URUQUIM_ODIN_BIN="$ODIN_BIN" \
  URUQUIM_ROOT="$URUQUIM_ROOT" \
  URUQUIM_TEST_DATABASE_URL="${URUQUIM_TEST_DATABASE_URL:-}" \
  bash "$CRYSTALS_ROOT/build/check_notes_controls.sh"
