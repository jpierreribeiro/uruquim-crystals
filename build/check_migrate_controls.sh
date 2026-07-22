#!/usr/bin/env bash
set -euo pipefail

# Migration Tool Crystal controls (WP79 contract).
#
#   1. An advisory-lock laboratory probe proving PostgreSQL gives the mutual
#      exclusion the runner relies on to stop two runners applying concurrently.
#   2. The db/migrate contract corpus, RED-under-control: it compiles, runs
#      against the pinned container, and fails only because the runner bodies
#      return Error_Kind.Unimplemented. WP80 implements them and turns it green.

CRYSTALS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ODIN_BIN="${URUQUIM_ODIN_BIN:-${URUQUIM_COMPILER:-odin}}"
URUQUIM_ROOT="${URUQUIM_ROOT:-}"
EXPECTED_IMAGE='postgres:16-alpine@sha256:20edbde7749f822887a1a022ad526fde0a47d6b2be9a8364433605cf65099416'
EXPECTED_DSN='postgresql://uruquim:uruquim_test_pw@127.0.0.1:55434/uruquim_crystals_test?sslmode=disable&require_auth=scram-sha-256'
DATABASE_URL="${URUQUIM_TEST_DATABASE_URL:-$EXPECTED_DSN}"

fail() {
  echo "MIGRATE-CONTROL-FAIL: $*" >&2
  exit 1
}

test "$DATABASE_URL" = "$EXPECTED_DSN" ||
  fail "integration probe refuses a database outside the dedicated harness"
command -v docker >/dev/null 2>&1 || fail "docker is required for the migrate harness"
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

TMP="$(mktemp -d -t uruquim-crystals-migrate-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

COLLECTIONS=(
  -collection:crystals="$CRYSTALS_ROOT"
  -collection:uruquim="$URUQUIM_ROOT"
)

# --- 1. advisory-lock laboratory probe ---

echo "migrate: proving PostgreSQL advisory-lock mutual exclusion"
"$ODIN_BIN" build "$CRYSTALS_ROOT/experiments/wp79-lock" \
  "${COLLECTIONS[@]}" \
  -define:POSTGRES_LIB="$LIBPQ_DEFINE" \
  -out:"$TMP/lock"
LOCK_OUTPUT="$(env URUQUIM_TEST_DATABASE_URL="$DATABASE_URL" "$TMP/lock")"
echo "$LOCK_OUTPUT" | grep -qx 'wp79-lock: exclusive=ok released=ok' ||
  fail "advisory-lock probe did not prove mutual exclusion"

# --- 2. the migration contract corpus is RED-under-control ---

echo "migrate: running the db/migrate contract corpus (expected RED until WP80)"
if "$ODIN_BIN" test "$CRYSTALS_ROOT/tests/migrate" \
  "${COLLECTIONS[@]}" \
  -define:POSTGRES_LIB="$LIBPQ_DEFINE" \
  -out:"$TMP/mig" >"$TMP/mig.log" 2>&1; then
  fail "the migrate corpus unexpectedly passed; it must be RED until WP80"
fi
grep -q 'Unimplemented' "$TMP/mig.log" ||
  fail "migrate corpus did not fail via the Unimplemented sentinel; RED is not under control"
grep -q 'All tests failed' "$TMP/mig.log" ||
  fail "not every migrate test is RED"
if grep -qiE 'segmentation|sigsegv|signal .* caught' "$TMP/mig.log"; then
  fail "migrate corpus failed by crashing rather than by controlled assertion"
fi

# Vacuity guard: the corpus asserts the real contract, not the sentinel.
if grep -vE '^[[:space:]]*//' "$CRYSTALS_ROOT/tests/migrate/migrate_test.odin" \
  | grep -qE '(MK|Error_Kind|mig\.Error_Kind)\.Unimplemented'; then
  fail "the migrate corpus must never assert on the Unimplemented sentinel"
fi
for kind in Duplicate_Id Checksum_Mismatch Dirty_State Apply_Failed; do
  grep -q "$kind" "$CRYSTALS_ROOT/tests/migrate/migrate_test.odin" ||
    fail "migrate corpus no longer covers $kind"
done

echo "$LOCK_OUTPUT"
echo "PASS: migration advisory-lock laboratory and RED-under-control contract corpus"
