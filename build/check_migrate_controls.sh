#!/usr/bin/env bash
set -euo pipefail

# Migration Tool Crystal controls (WP79 contract, WP80 runner).
#
#   1. An advisory-lock laboratory probe proving PostgreSQL mutual exclusion.
#   2. The db/migrate contract corpus, GREEN against the pinned container
#      (single-threaded: the corpus shares the history table and advisory lock).
#   3. A two-process control: two runner executables race to apply the same
#      migration; the advisory lock lets exactly one apply while the other is
#      refused, and the migration is recorded exactly once.
#   4. A mutation control that disables the dirty-state refusal and proves the
#      corpus catches it.

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

# psql helper for setup/inspection inside the pinned container.
psql_c() {
  docker exec -e PGPASSWORD=uruquim_test_pw uruquim-crystals-pg16 \
    psql -h 127.0.0.1 -U uruquim -d uruquim_crystals_test -tAc "$1"
}

# --- 1. advisory-lock laboratory probe ---

echo "migrate: proving PostgreSQL advisory-lock mutual exclusion"
"$ODIN_BIN" build "$CRYSTALS_ROOT/experiments/wp79-lock" \
  "${COLLECTIONS[@]}" -define:POSTGRES_LIB="$LIBPQ_DEFINE" -out:"$TMP/lock"
LOCK_OUTPUT="$(env URUQUIM_TEST_DATABASE_URL="$DATABASE_URL" "$TMP/lock")"
echo "$LOCK_OUTPUT" | grep -qx 'wp79-lock: exclusive=ok released=ok' ||
  fail "advisory-lock probe did not prove mutual exclusion"

# --- 2. the migration contract corpus is GREEN (single-threaded) ---

echo "migrate: running the db/migrate contract corpus (expected GREEN)"
"$ODIN_BIN" test "$CRYSTALS_ROOT/tests/migrate" \
  "${COLLECTIONS[@]}" \
  -define:POSTGRES_LIB="$LIBPQ_DEFINE" \
  -define:ODIN_TEST_THREADS=1 \
  -out:"$TMP/mig" >"$TMP/mig.log" 2>&1 ||
  { cat "$TMP/mig.log" >&2; fail "the migrate corpus is not green"; }
grep -q 'All tests were successful' "$TMP/mig.log" ||
  fail "the migrate corpus did not report all green"

# --- 3. two runner processes contend for the advisory lock ---

echo "migrate: two runners race to apply the same migration"
"$ODIN_BIN" build "$CRYSTALS_ROOT/cmd/migrate" \
  "${COLLECTIONS[@]}" -define:POSTGRES_LIB="$LIBPQ_DEFINE" -out:"$TMP/migrate-cli"

psql_c "DROP TABLE IF EXISTS _uruquim_migrations" >/dev/null

export MIGRATE_HOST=127.0.0.1 MIGRATE_PORT=55434 MIGRATE_USER=uruquim \
  MIGRATE_PASSWORD=uruquim_test_pw MIGRATE_DB=uruquim_crystals_test \
  MIGRATE_ALLOW_PLAINTEXT=1 MIGRATE_SSLMODE=disable \
  MIGRATE_DIR="$CRYSTALS_ROOT/tests/migrate/fixtures/slow"

"$TMP/migrate-cli" up >"$TMP/a.log" 2>&1 &
A=$!
"$TMP/migrate-cli" up >"$TMP/b.log" 2>&1 &
B=$!
set +e
wait $A; RA=$?
wait $B; RB=$?
set -e

# Neither process may crash: each either applied cleanly (exit 0) or was refused
# with Lock_Failed (exit 1). A duplicate-key crash would mean the lock failed.
for pair in "$RA:$TMP/a.log" "$RB:$TMP/b.log"; do
  code="${pair%%:*}"
  log="${pair#*:}"
  if [ "$code" -ne 0 ] && ! grep -q 'Lock_Failed' "$log"; then
    echo "--- runner log ---" >&2; cat "$log" >&2
    fail "a runner failed for a reason other than the advisory lock (exit $code)"
  fi
done

APPLIED_COUNT="$(psql_c "SELECT count(*) FROM _uruquim_migrations WHERE NOT dirty")"
test "$APPLIED_COUNT" = "1" ||
  fail "the migration was recorded $APPLIED_COUNT times, expected exactly 1"
echo "migrate: two runners serialized on the advisory lock; the migration applied once"

# --- 4. mutation control: disabling the dirty-state refusal must fail the corpus ---

echo "migrate: mutation control (disabled dirty refusal must fail the corpus)"
mkdir -p "$TMP/mut/db"
cp -r "$CRYSTALS_ROOT/db/migrate" "$TMP/mut/db/migrate"
cp -r "$CRYSTALS_ROOT/db/postgres" "$TMP/mut/db/postgres"
cp -r "$CRYSTALS_ROOT/vendor" "$TMP/mut/vendor"
MUT_DEFINE="$(realpath --relative-to="$TMP/mut/vendor/odin-postgresql" "$LIBPQ_PATH")"
sed -i 's/if h\.dirty {/if false {/' "$TMP/mut/db/migrate/runner.odin"
if "$ODIN_BIN" test "$CRYSTALS_ROOT/tests/migrate" \
  -collection:crystals="$TMP/mut" -collection:uruquim="$URUQUIM_ROOT" \
  -define:POSTGRES_LIB="$MUT_DEFINE" -define:ODIN_TEST_THREADS=1 \
  -out:"$TMP/mut-mig" >/dev/null 2>&1; then
  fail "disabled dirty-state refusal unexpectedly passed; the corpus is not evidence"
fi
echo "migrate: mutation control caught the disabled dirty-state refusal"

echo "$LOCK_OUTPUT"
echo "PASS: migration runner, advisory-lock serialization and fail-closed history"
