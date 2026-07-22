#!/usr/bin/env bash
set -euo pipefail

# WP75 — PostgreSQL wire/error laboratory controls.
#
# Two independent bodies of evidence:
#
#   1. A raw-libpq laboratory probe proving the pinned server really produces
#      every condition the RED corpus targets (SQLSTATE integrity violations,
#      NULL distinct from empty/zero, parameter separation, a server-confirmed
#      statement-timeout cancellation and connection-loss uncertainty), plus a
#      negative control proving the probe can fail.
#
#   2. The db/postgres RED corpus, proven RED-under-control: it compiles, runs,
#      and fails only because the wrapper bodies return Error_Kind.Unimplemented
#      — never because of a crash, a compile error or a weakened assertion.
#
# WP76 consumes this corpus and turns execution/decoding green; this control is
# updated at that point, but the laboratory probe evidence is permanent.

CRYSTALS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ODIN_BIN="${URUQUIM_ODIN_BIN:-${URUQUIM_COMPILER:-odin}}"
URUQUIM_ROOT="${URUQUIM_ROOT:-}"
EXPECTED_IMAGE='postgres:16-alpine@sha256:20edbde7749f822887a1a022ad526fde0a47d6b2be9a8364433605cf65099416'
EXPECTED_DSN='postgresql://uruquim:uruquim_test_pw@127.0.0.1:55434/uruquim_crystals_test?sslmode=disable&require_auth=scram-sha-256'
DATABASE_URL="${URUQUIM_TEST_DATABASE_URL:-$EXPECTED_DSN}"

fail() {
  echo "WP75-CONTROL-FAIL: $*" >&2
  exit 1
}

test "$DATABASE_URL" = "$EXPECTED_DSN" ||
  fail "integration probe refuses a database outside the dedicated WP75 harness"
command -v docker >/dev/null 2>&1 || fail "docker is required for the WP75 harness"
command -v ldconfig >/dev/null 2>&1 || fail "ldconfig is required to locate libpq.so.5"

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

TMP="$(mktemp -d -t uruquim-crystals-wp75-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. laboratory probe proves the real server conditions ---

echo "wp75: compiling the raw-libpq laboratory probe"
"$ODIN_BIN" build "$CRYSTALS_ROOT/experiments/wp75-lab" \
  -collection:crystals="$CRYSTALS_ROOT" \
  -define:POSTGRES_LIB="$LIBPQ_DEFINE" \
  -out:"$TMP/wp75-lab"

echo "wp75: running the laboratory probe against the dedicated PostgreSQL 16 harness"
LAB_OUTPUT="$(env URUQUIM_TEST_DATABASE_URL="$DATABASE_URL" "$TMP/wp75-lab")"
echo "$LAB_OUTPUT" | grep -qx \
  'wp75-lab: integrity=ok null_distinct=ok params=ok overflow=ok timeout=57014 conn_loss=bad' ||
  fail "laboratory probe did not prove every targeted server condition"

# Negative control: a probe that expects the wrong SQLSTATE must fail, proving
# the probe genuinely checks the server rather than always passing.
mkdir -p "$TMP/mutant-lab"
cp "$CRYSTALS_ROOT/experiments/wp75-lab/main.odin" "$TMP/mutant-lab/main.odin"
sed -i 's/"23505"/"00000"/' "$TMP/mutant-lab/main.odin"
"$ODIN_BIN" build "$TMP/mutant-lab" \
  -collection:crystals="$CRYSTALS_ROOT" \
  -define:POSTGRES_LIB="$LIBPQ_DEFINE" \
  -out:"$TMP/wp75-lab-mutant" >/dev/null 2>&1 ||
  fail "mutant laboratory probe did not compile"
if env URUQUIM_TEST_DATABASE_URL="$DATABASE_URL" "$TMP/wp75-lab-mutant" >/dev/null 2>&1; then
  fail "mutated laboratory probe unexpectedly passed"
fi
echo "wp75: laboratory probe and its negative control are sound"

# --- 2. the RED corpus is RED-under-control ---

COLLECTIONS=(-collection:crystals="$CRYSTALS_ROOT")
if test -d "$URUQUIM_ROOT/web"; then
  COLLECTIONS+=(-collection:uruquim="$URUQUIM_ROOT")
fi

echo "wp75: running the db/postgres RED corpus (expected RED-under-control)"
CORPUS_LOG="$TMP/corpus.log"
if "$ODIN_BIN" test "$CRYSTALS_ROOT/tests/postgres" \
  "${COLLECTIONS[@]}" \
  -out:"$TMP/wp75-corpus" >"$CORPUS_LOG" 2>&1; then
  fail "the WP75 corpus unexpectedly passed; it must be RED until WP76 implements the wrapper"
fi

# Under control: every failure is the pending-implementation sentinel, and there
# is no crash or compile failure masquerading as RED.
grep -q 'Unimplemented' "$CORPUS_LOG" ||
  fail "corpus did not fail via the Unimplemented sentinel; the RED is not under control"
grep -q 'All tests failed' "$CORPUS_LOG" ||
  fail "not every corpus test is RED; a green test cannot rest on the skeleton"
if grep -qiE 'segmentation|sigsegv|signal .* caught|out of memory' "$CORPUS_LOG"; then
  fail "corpus failed by crashing rather than by controlled assertion"
fi

# Vacuity guard: the corpus must assert on the real typed contract, not on the
# sentinel. If someone gutted it to assert Unimplemented, this catches it.
grep -vE '^[[:space:]]*//' "$CRYSTALS_ROOT/tests/postgres/wire_lab_test.odin" \
  | grep -qE '(K|Error_Kind|pg\.Error_Kind)\.Unimplemented' &&
  fail "the corpus must never assert on the Unimplemented sentinel"
for kind in Unique_Violation Foreign_Key_Violation Not_Null_Violation Check_Violation \
            Decode_Null Decode_Type_Mismatch Decode_Overflow Decode_Shape \
            Row_Not_Found Too_Many_Rows Auth_Failed Config_Invalid \
            Connection_Lost Timeout Result_Too_Large Closed; do
  grep -q "$kind" "$CRYSTALS_ROOT/tests/postgres/wire_lab_test.odin" ||
    fail "corpus no longer covers $kind"
done

echo "wp75: RED corpus is real, exhaustive and RED-under-control"
echo "$LAB_OUTPUT"
echo "PASS: WP75 PostgreSQL wire/error laboratory"
