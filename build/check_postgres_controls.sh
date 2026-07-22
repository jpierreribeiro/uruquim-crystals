#!/usr/bin/env bash
set -euo pipefail

# PostgreSQL Service Crystal controls (WP75 laboratory, WP76 execution, WP77 pool).
#
# Evidence, in order:
#
#   1. A raw-libpq laboratory probe proving the pinned server really produces
#      every condition the corpus targets, with a negative control that mutates
#      an expected SQLSTATE and must fail (WP75, permanent).
#   2. The db/postgres execution/decoding/deadline/bounds corpus, GREEN against
#      the container: connection/auth policy, typed SQLSTATE kinds, parameter
#      separation, NULL distinct from empty/zero, fail-closed decoding,
#      cardinality, connection-loss quarantine, statement-timeout cancellation
#      and bounded results (WP76 + WP77).
#   3. The bounded-pool corpus, GREEN: acquire/release, min_conns readiness,
#      typed Pool_Exhausted under saturation, broken-connection quarantine and
#      closed-pool refusal (WP77).
#   4. Mutation controls that break the SQLSTATE→kind map and the pool's
#      broken-connection discard, proving each green suite catches it — a suite
#      that cannot fail is not evidence.

CRYSTALS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ODIN_BIN="${URUQUIM_ODIN_BIN:-${URUQUIM_COMPILER:-odin}}"
URUQUIM_ROOT="${URUQUIM_ROOT:-}"
EXPECTED_IMAGE='postgres:16-alpine@sha256:20edbde7749f822887a1a022ad526fde0a47d6b2be9a8364433605cf65099416'
EXPECTED_DSN='postgresql://uruquim:uruquim_test_pw@127.0.0.1:55434/uruquim_crystals_test?sslmode=disable&require_auth=scram-sha-256'
DATABASE_URL="${URUQUIM_TEST_DATABASE_URL:-$EXPECTED_DSN}"

fail() {
  echo "POSTGRES-CONTROL-FAIL: $*" >&2
  exit 1
}

test "$DATABASE_URL" = "$EXPECTED_DSN" ||
  fail "integration probe refuses a database outside the dedicated harness"
command -v docker >/dev/null 2>&1 || fail "docker is required for the PostgreSQL harness"
command -v ldconfig >/dev/null 2>&1 || fail "ldconfig is required to locate libpq.so.5"
test -d "$URUQUIM_ROOT/web" || fail "set URUQUIM_ROOT to the pinned Uruquim checkout"

# --- dedicated container, pinned by digest and loopback port ---

if ! docker inspect uruquim-crystals-pg16 >/dev/null 2>&1; then
  docker run --detach \
    --name uruquim-crystals-pg16 \
    --env POSTGRES_USER=uruquim \
    --env POSTGRES_PASSWORD=uruquim_test_pw \
    --env POSTGRES_DB=uruquim_crystals_test \
    --publish 127.0.0.1:55434:5432 \
    "$EXPECTED_IMAGE" >/dev/null
fi

ACTUAL_IMAGE="$(docker inspect uruquim-crystals-pg16 --format '{{.Config.Image}}')"
test "$ACTUAL_IMAGE" = "$EXPECTED_IMAGE" ||
  fail "uruquim-crystals-pg16 does not use the pinned PostgreSQL image"
EXPECTED_IMAGE_ID="$(docker image inspect "$EXPECTED_IMAGE" --format '{{.Id}}')"
ACTUAL_IMAGE_ID="$(docker inspect uruquim-crystals-pg16 --format '{{.Image}}')"
test "$ACTUAL_IMAGE_ID" = "$EXPECTED_IMAGE_ID" ||
  fail "uruquim-crystals-pg16 image ID differs from the pinned digest"
test "$(docker port uruquim-crystals-pg16 5432/tcp)" = '127.0.0.1:55434' ||
  fail "uruquim-crystals-pg16 is not bound to the dedicated loopback port"
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

# --- locate libpq for the -define the compiler needs ---

LIBPQ_PATH="${URUQUIM_LIBPQ_PATH:-}"
if test -z "$LIBPQ_PATH"; then
  LIBPQ_PATH="$(ldconfig -p | awk '/libpq\.so\.5 \(/{print $NF; exit}')"
fi
test -n "$LIBPQ_PATH" && test -f "$LIBPQ_PATH" ||
  fail "libpq.so.5 was not found; install a supported libpq runtime"
LIBPQ_PATH="$(readlink -f "$LIBPQ_PATH")"
LIBPQ_DEFINE="$(realpath --relative-to="$CRYSTALS_ROOT/vendor/odin-postgresql" "$LIBPQ_PATH")"

TMP="$(mktemp -d -t uruquim-crystals-postgres-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

COLLECTIONS=(
  -collection:crystals="$CRYSTALS_ROOT"
  -collection:uruquim="$URUQUIM_ROOT"
)

# --- 1. laboratory probe proves the real server conditions ---

echo "postgres: compiling the raw-libpq laboratory probe"
"$ODIN_BIN" build "$CRYSTALS_ROOT/experiments/wp75-lab" \
  -collection:crystals="$CRYSTALS_ROOT" \
  -define:POSTGRES_LIB="$LIBPQ_DEFINE" \
  -out:"$TMP/lab"
LAB_OUTPUT="$(env URUQUIM_TEST_DATABASE_URL="$DATABASE_URL" "$TMP/lab")"
echo "$LAB_OUTPUT" | grep -qx \
  'wp75-lab: integrity=ok null_distinct=ok params=ok overflow=ok timeout=57014 conn_loss=bad' ||
  fail "laboratory probe did not prove every targeted server condition"

mkdir -p "$TMP/mutant-lab"
cp "$CRYSTALS_ROOT/experiments/wp75-lab/main.odin" "$TMP/mutant-lab/main.odin"
sed -i 's/"23505"/"00000"/' "$TMP/mutant-lab/main.odin"
"$ODIN_BIN" build "$TMP/mutant-lab" \
  -collection:crystals="$CRYSTALS_ROOT" \
  -define:POSTGRES_LIB="$LIBPQ_DEFINE" \
  -out:"$TMP/lab-mutant" >/dev/null 2>&1 || fail "mutant laboratory probe did not compile"
if env URUQUIM_TEST_DATABASE_URL="$DATABASE_URL" "$TMP/lab-mutant" >/dev/null 2>&1; then
  fail "mutated laboratory probe unexpectedly passed"
fi
echo "postgres: laboratory probe and its negative control are sound"

# --- 2. the execution/decoding/deadline/bounds corpus is GREEN ---

echo "postgres: running the db/postgres execution corpus (expected GREEN)"
"$ODIN_BIN" test "$CRYSTALS_ROOT/tests/postgres" \
  "${COLLECTIONS[@]}" \
  -define:POSTGRES_LIB="$LIBPQ_DEFINE" \
  -out:"$TMP/corpus" >"$TMP/corpus.log" 2>&1 ||
  { cat "$TMP/corpus.log" >&2; fail "the execution corpus is not green"; }
grep -q 'All tests were successful' "$TMP/corpus.log" ||
  fail "the execution corpus did not report all green"

# --- 3. the bounded-pool corpus is GREEN ---

echo "postgres: running the bounded-pool corpus (expected GREEN)"
"$ODIN_BIN" test "$CRYSTALS_ROOT/tests/postgres_pool" \
  "${COLLECTIONS[@]}" \
  -define:POSTGRES_LIB="$LIBPQ_DEFINE" \
  -out:"$TMP/pool" >"$TMP/pool.log" 2>&1 ||
  { cat "$TMP/pool.log" >&2; fail "the bounded-pool corpus is not green"; }
grep -q 'All tests were successful' "$TMP/pool.log" ||
  fail "the bounded-pool corpus did not report all green"

echo "postgres: running the transaction corpus (expected GREEN)"
"$ODIN_BIN" test "$CRYSTALS_ROOT/tests/postgres_tx" \
  "${COLLECTIONS[@]}" \
  -define:POSTGRES_LIB="$LIBPQ_DEFINE" \
  -out:"$TMP/tx" >"$TMP/tx.log" 2>&1 ||
  { cat "$TMP/tx.log" >&2; fail "the transaction corpus is not green"; }
grep -q 'All tests were successful' "$TMP/tx.log" ||
  fail "the transaction corpus did not report all green"

# --- 4. mutation controls: each green suite must be able to fail ---

mkdir -p "$TMP/mut/db"
cp -r "$CRYSTALS_ROOT/db/postgres" "$TMP/mut/db/postgres"
cp -r "$CRYSTALS_ROOT/vendor" "$TMP/mut/vendor"
MUT_DEFINE="$(realpath --relative-to="$TMP/mut/vendor/odin-postgresql" "$LIBPQ_PATH")"

echo "postgres: mutation control (broken SQLSTATE map must fail the execution corpus)"
cp "$CRYSTALS_ROOT/db/postgres/internal.odin" "$TMP/mut/db/postgres/internal.odin"
sed -i 's/return \.Unique_Violation/return .Query_Failed/' "$TMP/mut/db/postgres/internal.odin"
if "$ODIN_BIN" test "$CRYSTALS_ROOT/tests/postgres" \
  -collection:crystals="$TMP/mut" -collection:uruquim="$URUQUIM_ROOT" \
  -define:POSTGRES_LIB="$MUT_DEFINE" -out:"$TMP/mut-corpus" >/dev/null 2>&1; then
  fail "SQLSTATE-mapping mutation unexpectedly passed; the green corpus is not evidence"
fi

echo "postgres: mutation control (pool keeping a broken connection must fail the pool corpus)"
cp "$CRYSTALS_ROOT/db/postgres/internal.odin" "$TMP/mut/db/postgres/internal.odin"
cp "$CRYSTALS_ROOT/db/postgres/pool.odin" "$TMP/mut/db/postgres/pool.odin"
sed -i 's/is_broken(c) || conn_expired(p, c)/conn_expired(p, c)/' "$TMP/mut/db/postgres/pool.odin"
if "$ODIN_BIN" test "$CRYSTALS_ROOT/tests/postgres_pool" \
  -collection:crystals="$TMP/mut" -collection:uruquim="$URUQUIM_ROOT" \
  -define:POSTGRES_LIB="$MUT_DEFINE" -out:"$TMP/mut-pool" >/dev/null 2>&1; then
  fail "broken-connection-discard mutation unexpectedly passed; the pool corpus is not evidence"
fi

echo "postgres: mutation control (a rollback that does not roll back must fail the tx corpus)"
cp "$CRYSTALS_ROOT/db/postgres/pool.odin" "$TMP/mut/db/postgres/pool.odin"
cp "$CRYSTALS_ROOT/db/postgres/tx.odin" "$TMP/mut/db/postgres/tx.odin"
sed -i 's/tx._name, "ROLLBACK"/tx._name, "SELECT 1"/' "$TMP/mut/db/postgres/tx.odin"
if "$ODIN_BIN" test "$CRYSTALS_ROOT/tests/postgres_tx" \
  -collection:crystals="$TMP/mut" -collection:uruquim="$URUQUIM_ROOT" \
  -define:POSTGRES_LIB="$MUT_DEFINE" -out:"$TMP/mut-tx" >/dev/null 2>&1; then
  fail "no-op-rollback mutation unexpectedly passed; the tx corpus is not evidence"
fi
echo "postgres: mutation controls caught the broken SQLSTATE map, broken-connection reuse and a no-op rollback"

echo "$LAB_OUTPUT"
echo "PASS: PostgreSQL execution, decoding, deadlines, bounds and bounded pool"
