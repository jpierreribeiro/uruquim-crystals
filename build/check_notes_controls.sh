#!/usr/bin/env bash
set -euo pipefail

# Reference application controls (WP83).
#
#   1. The deployable notes server executable builds.
#   2. The integration corpus runs GREEN against the pinned container: CRUD,
#      strict JSON, structured validation, SQL NULL, three-state PATCH, a unique
#      conflict, keyset pagination, a bounded pool that fails fast, a blocked
#      query that does not stall health, query cancellation and clean shutdown.
#   3. A mutation control that breaks the three-state PATCH and proves the corpus
#      catches it.

CRYSTALS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ODIN_BIN="${URUQUIM_ODIN_BIN:-${URUQUIM_COMPILER:-odin}}"
URUQUIM_ROOT="${URUQUIM_ROOT:-}"
EXPECTED_IMAGE='postgres:16-alpine@sha256:20edbde7749f822887a1a022ad526fde0a47d6b2be9a8364433605cf65099416'
EXPECTED_DSN='postgresql://uruquim:uruquim_test_pw@127.0.0.1:55434/uruquim_crystals_test?sslmode=disable&require_auth=scram-sha-256'
DATABASE_URL="${URUQUIM_TEST_DATABASE_URL:-$EXPECTED_DSN}"

fail() {
  echo "NOTES-CONTROL-FAIL: $*" >&2
  exit 1
}

test "$DATABASE_URL" = "$EXPECTED_DSN" ||
  fail "integration probe refuses a database outside the dedicated harness"
command -v docker >/dev/null 2>&1 || fail "docker is required for the notes harness"
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

TMP="$(mktemp -d -t uruquim-crystals-notes-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

COLLECTIONS=(
  -collection:crystals="$CRYSTALS_ROOT"
  -collection:uruquim="$URUQUIM_ROOT"
)

echo "notes: building the deployable server executable"
"$ODIN_BIN" build "$CRYSTALS_ROOT/examples/notes/cmd" \
  "${COLLECTIONS[@]}" -define:POSTGRES_LIB="$LIBPQ_DEFINE" -out:"$TMP/notes-server"

echo "notes: running the reference-application corpus (expected GREEN)"
"$ODIN_BIN" test "$CRYSTALS_ROOT/tests/notes" \
  "${COLLECTIONS[@]}" \
  -define:POSTGRES_LIB="$LIBPQ_DEFINE" \
  -define:ODIN_TEST_THREADS=1 \
  -out:"$TMP/notes" >"$TMP/notes.log" 2>&1 ||
  { cat "$TMP/notes.log" >&2; fail "the reference-application corpus is not green"; }
grep -q 'All tests were successful' "$TMP/notes.log" ||
  fail "the reference-application corpus did not report all green"

echo "notes: mutation control (a PATCH that overwrites an absent field must fail the corpus)"
mkdir -p "$TMP/mut"
cp -r "$CRYSTALS_ROOT/examples" "$TMP/mut/examples"
cp -r "$CRYSTALS_ROOT/db" "$TMP/mut/db"
cp -r "$CRYSTALS_ROOT/web" "$TMP/mut/web"
cp -r "$CRYSTALS_ROOT/validate" "$TMP/mut/validate"
cp -r "$CRYSTALS_ROOT/vendor" "$TMP/mut/vendor"
MUT_DEFINE="$(realpath --relative-to="$TMP/mut/vendor/odin-postgresql" "$LIBPQ_PATH")"
sed -i 's/body_present := body_p.state != .Absent/body_present := true/' "$TMP/mut/examples/notes/notes.odin"
if "$ODIN_BIN" test "$CRYSTALS_ROOT/tests/notes" \
  -collection:crystals="$TMP/mut" -collection:uruquim="$URUQUIM_ROOT" \
  -define:POSTGRES_LIB="$MUT_DEFINE" -define:ODIN_TEST_THREADS=1 \
  -out:"$TMP/mut-notes" >/dev/null 2>&1; then
  fail "a PATCH overwriting an absent field unexpectedly passed; the corpus is not evidence"
fi
echo "notes: mutation control caught the broken three-state PATCH"
echo "PASS: reference application demonstrates the full data-stack contract"
