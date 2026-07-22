#!/usr/bin/env bash
set -euo pipefail

# Optional SQL/schema checker controls (WP82).
#
#   1. The db/sqlcheck corpus, GREEN against the pinned container: it prepares
#      each query against the real schema and classifies it Ok / Prepare_Failed /
#      Param_Count_Mismatch / Result_Mismatch / Unchecked, and proves the full
#      workflow (migrate, then check).
#   2. A mutation control that stops flagging a Prepare_Failed and proves the
#      corpus catches it.

CRYSTALS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ODIN_BIN="${URUQUIM_ODIN_BIN:-${URUQUIM_COMPILER:-odin}}"
URUQUIM_ROOT="${URUQUIM_ROOT:-}"
EXPECTED_IMAGE='postgres:16-alpine@sha256:20edbde7749f822887a1a022ad526fde0a47d6b2be9a8364433605cf65099416'
EXPECTED_DSN='postgresql://uruquim:uruquim_test_pw@127.0.0.1:55434/uruquim_crystals_test?sslmode=disable&require_auth=scram-sha-256'
DATABASE_URL="${URUQUIM_TEST_DATABASE_URL:-$EXPECTED_DSN}"

fail() {
  echo "SQLCHECK-CONTROL-FAIL: $*" >&2
  exit 1
}

test "$DATABASE_URL" = "$EXPECTED_DSN" ||
  fail "integration probe refuses a database outside the dedicated harness"
command -v docker >/dev/null 2>&1 || fail "docker is required for the sqlcheck harness"
test -d "$URUQUIM_ROOT/web" || fail "set URUQUIM_ROOT to the pinned Uruquim checkout"

if ! docker inspect uruquim-crystals-pg16 >/dev/null 2>&1; then
  docker run --detach --name uruquim-crystals-pg16 \
    --env POSTGRES_USER=uruquim --env POSTGRES_PASSWORD=uruquim_test_pw \
    --env POSTGRES_DB=uruquim_crystals_test --publish 127.0.0.1:55434:5432 \
    "$EXPECTED_IMAGE" >/dev/null
fi
if test "$(docker inspect uruquim-crystals-pg16 --format '{{.State.Running}}')" != true; then
  docker start uruquim-crystals-pg16 >/dev/null
fi
READY=false
for _ in $(seq 1 60); do
  if docker exec uruquim-crystals-pg16 \
    pg_isready --quiet --username uruquim --dbname uruquim_crystals_test; then
    READY=true
    break
  fi
  sleep 0.25
done
test "$READY" = true || fail "dedicated PostgreSQL did not become ready within 15 seconds"

LIBPQ_PATH="${URUQUIM_LIBPQ_PATH:-}"
if test -z "$LIBPQ_PATH"; then
  LIBPQ_PATH="$(ldconfig -p | awk '/libpq\.so\.5 \(/{print $NF; exit}')"
fi
test -n "$LIBPQ_PATH" && test -f "$LIBPQ_PATH" || fail "libpq.so.5 was not found"
LIBPQ_PATH="$(readlink -f "$LIBPQ_PATH")"
LIBPQ_DEFINE="$(realpath --relative-to="$CRYSTALS_ROOT/vendor/odin-postgresql" "$LIBPQ_PATH")"

TMP="$(mktemp -d -t uruquim-crystals-sqlcheck-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

COLLECTIONS=(
  -collection:crystals="$CRYSTALS_ROOT"
  -collection:uruquim="$URUQUIM_ROOT"
)

echo "sqlcheck: running the checker corpus (expected GREEN)"
"$ODIN_BIN" test "$CRYSTALS_ROOT/tests/sqlcheck" \
  "${COLLECTIONS[@]}" \
  -define:POSTGRES_LIB="$LIBPQ_DEFINE" \
  -define:ODIN_TEST_THREADS=1 \
  -out:"$TMP/sc" >"$TMP/sc.log" 2>&1 ||
  { cat "$TMP/sc.log" >&2; fail "the sqlcheck corpus is not green"; }
grep -q 'All tests were successful' "$TMP/sc.log" ||
  fail "the sqlcheck corpus did not report all green"

echo "sqlcheck: mutation control (a Prepare_Failed misclassified as Ok must fail the corpus)"
mkdir -p "$TMP/mut/db"
cp -r "$CRYSTALS_ROOT/db/sqlcheck" "$TMP/mut/db/sqlcheck"
cp -r "$CRYSTALS_ROOT/db/postgres" "$TMP/mut/db/postgres"
cp -r "$CRYSTALS_ROOT/db/migrate" "$TMP/mut/db/migrate"
cp -r "$CRYSTALS_ROOT/vendor" "$TMP/mut/vendor"
MUT_DEFINE="$(realpath --relative-to="$TMP/mut/vendor/odin-postgresql" "$LIBPQ_PATH")"
sed -i 's/f.kind = .Prepare_Failed/f.kind = .Ok/' "$TMP/mut/db/sqlcheck/sqlcheck.odin"
if "$ODIN_BIN" test "$CRYSTALS_ROOT/tests/sqlcheck" \
  -collection:crystals="$TMP/mut" -collection:uruquim="$URUQUIM_ROOT" \
  -define:POSTGRES_LIB="$MUT_DEFINE" -define:ODIN_TEST_THREADS=1 \
  -out:"$TMP/mut-sc" >/dev/null 2>&1; then
  fail "misclassified Prepare_Failed unexpectedly passed; the sqlcheck corpus is not evidence"
fi
echo "sqlcheck: mutation control caught the misclassification"
echo "PASS: optional SQL/schema checker prepares and classifies against the real schema"
