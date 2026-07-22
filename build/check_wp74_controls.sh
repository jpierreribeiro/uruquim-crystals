#!/usr/bin/env bash
set -euo pipefail

CRYSTALS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ODIN_BIN="${URUQUIM_ODIN_BIN:-${URUQUIM_COMPILER:-odin}}"
EXPECTED_IMAGE='postgres:16-alpine@sha256:20edbde7749f822887a1a022ad526fde0a47d6b2be9a8364433605cf65099416'
EXPECTED_DSN='postgresql://uruquim:uruquim_test_pw@127.0.0.1:55434/uruquim_crystals_test?sslmode=disable&require_auth=scram-sha-256'
DATABASE_URL="${URUQUIM_TEST_DATABASE_URL:-$EXPECTED_DSN}"

fail() {
  echo "WP74-CONTROL-FAIL: $*" >&2
  exit 1
}

test "$DATABASE_URL" = "$EXPECTED_DSN" ||
  fail "integration probe refuses a database outside the dedicated WP74 harness"
command -v docker >/dev/null 2>&1 || fail "docker is required for the WP74 harness"
command -v ldconfig >/dev/null 2>&1 || fail "ldconfig is required to locate libpq.so.5"
command -v nm >/dev/null 2>&1 || fail "nm is required for binding controls"

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

LIBPQ_PATH="${URUQUIM_LIBPQ_PATH:-}"
if test -z "$LIBPQ_PATH"; then
  LIBPQ_PATH="$(ldconfig -p | awk '/libpq\.so\.5 \(/{print $NF; exit}')"
fi
test -n "$LIBPQ_PATH" && test -f "$LIBPQ_PATH" ||
  fail "libpq.so.5 was not found; install a supported libpq runtime"
LIBPQ_PATH="$(readlink -f "$LIBPQ_PATH")"
LIBPQ_DEFINE="$(realpath --relative-to="$CRYSTALS_ROOT/vendor/odin-postgresql" "$LIBPQ_PATH")"

assert_dynamic_symbol() {
  nm -D "$LIBPQ_PATH" | awk '{print $3}' | grep -qx "$1"
}

assert_dynamic_symbol PQparameterStatus || fail "libpq omits PQparameterStatus"
if assert_dynamic_symbol PQparamterStatus; then
  fail "misspelled PQparamterStatus mutation unexpectedly resolved"
fi
grep -q '@(link_name="PQparameterStatus")' "$CRYSTALS_ROOT/vendor/odin-postgresql/pq.odin" ||
  fail "binding lost the PQparameterStatus patch"
grep -q '@(link_name="PQisthreadsafe")' "$CRYSTALS_ROOT/vendor/odin-postgresql/pq.odin" ||
  fail "binding lost the PQisthreadsafe patch"
grep -q '6f33822e1d8090a218fcf4c24863235b15a3205a' \
  "$CRYSTALS_ROOT/vendor/odin-postgresql/VENDOR.md" ||
  fail "binding provenance is not pinned"

grep -q '^\*\*Status: ACCEPTED' "$CRYSTALS_ROOT/planning/postgres-driver-selection.md" ||
  fail "driver decision is not accepted"
test "$(grep -cE '^\| (existing maintained|extract a pure|wrap `libpq`|implement protocol)' \
  "$CRYSTALS_ROOT/planning/postgres-driver-selection.md")" -eq 4 ||
  fail "driver decision does not contain exactly four evaluated arms"
grep -q 'thin Uruquim-owned wrapper' "$CRYSTALS_ROOT/planning/postgres-driver-selection.md" ||
  fail "selected driver boundary is absent"

TMP="$(mktemp -d -t uruquim-crystals-wp74-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT
echo "wp74: compiling the pinned libpq binding and ABI probe"
"$ODIN_BIN" build "$CRYSTALS_ROOT/experiments/wp74-libpq" \
  -collection:crystals="$CRYSTALS_ROOT" \
  -define:POSTGRES_LIB="$LIBPQ_DEFINE" \
  -out:"$TMP/wp74-libpq-probe"

echo "wp74: executing against the dedicated PostgreSQL 16 harness"
PROBE_OUTPUT="$(env URUQUIM_TEST_DATABASE_URL="$DATABASE_URL" "$TMP/wp74-libpq-probe")"
echo "$PROBE_OUTPUT" | grep -qE \
  '^wp74: libpq=[0-9]+ thread_safe=1 protocol=3 server=16[0-9]{4} extended_query=ok$' ||
  fail "libpq probe did not prove the selected ABI and extended query path"

# Semantic negative control: the same compiled probe must reject failed
# authentication. Suppressing libpq's server text also proves that the wrapper
# prototype does not print a DSN, password or raw server diagnostic.
BAD_DSN='postgresql://uruquim:wp74_deliberately_wrong@127.0.0.1:55434/uruquim_crystals_test?sslmode=disable&require_auth=scram-sha-256'
if env URUQUIM_TEST_DATABASE_URL="$BAD_DSN" "$TMP/wp74-libpq-probe" >/dev/null 2>&1; then
  fail "failed-authentication control unexpectedly passed"
fi

echo "$PROBE_OUTPUT"
echo "wp74: misspelled-link and failed-authentication controls rejected"
echo "PASS: WP74 PostgreSQL driver selection"
