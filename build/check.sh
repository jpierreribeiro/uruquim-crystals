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

DOC="$TMP/health-doc"
"$ODIN_BIN" doc "$CRYSTALS_ROOT/web/health" -short \
  -collection:uruquim="$URUQUIM_ROOT" \
  -collection:crystals="$CRYSTALS_ROOT" >"$DOC"
grep -qE '^\s*routes\s*::' "$DOC" || fail "routes is absent from compiler inventory"
if grep -E '^\s*[A-Za-z_][A-Za-z0-9_]*\s*::' "$DOC" | grep -vE '^\s*routes\s*::' >/dev/null 2>&1; then
  fail "web/health exports a symbol outside its one-row ledger"
fi

grep -Rqs 'uruquim:web/internal' "$CRYSTALS_ROOT/web" &&
  fail "a Crystal imports core internals"
grep -RqsE '\.(private)\b' "$CRYSTALS_ROOT/web" &&
  fail "a Crystal reaches core private state"

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

test "$(grep -vc '^#\|^$' "$CRYSTALS_ROOT/build/public-api.txt")" -eq 1 ||
  fail "first Crystal ledger is not exactly one symbol"

echo "crystals: web/health exports one detached Router constructor"
echo "crystals: core dependency is one-way and pinned at $EXPECTED_CORE"
echo "PASS: WP73 first Route Crystal"
