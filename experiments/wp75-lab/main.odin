package main

// WP75 laboratory probe. Using only the raw pinned libpq binding, it proves
// that the real pinned PostgreSQL server produces every condition the RED
// corpus in tests/postgres asserts the wrapper must handle: SQLSTATE integrity
// violations, NULL distinct from empty/zero, parameter separation, a
// server-confirmed statement-timeout cancellation (57014) and an uncertain
// connection after backend termination. The wrapper does not exist here; this
// is the wire-level evidence that the corpus targets are real, not invented.

import "core:fmt"
import "core:os"
import "core:strings"
import pq "crystals:vendor/odin-postgresql"

fail :: proc(msg: string) -> ! {
	fmt.eprintln("wp75-lab:", msg)
	os.exit(1)
}

// run executes a command with no parameters and returns its result. The caller
// clears it.
run :: proc(conn: pq.Conn, sql: string) -> pq.Result {
	c := strings.clone_to_cstring(sql)
	defer delete_cstring(c)
	return pq.exec(conn, c)
}

// sqlstate_of returns the five-character SQLSTATE of a failed result, or "".
sqlstate_of :: proc(res: pq.Result) -> string {
	f := pq.result_error_field(res, .SQL_State)
	if f == nil {
		return ""
	}
	return string(f)
}

// expect_sqlstate runs a statement that must fail with the given SQLSTATE.
expect_sqlstate :: proc(conn: pq.Conn, sql: string, want: string, label: string) {
	res := run(conn, sql)
	defer pq.clear(res)
	st := pq.result_status(res)
	if st != .Fatal_Error {
		fail(fmt.tprintf("%s: expected a fatal error, got status %v", label, st))
	}
	got := sqlstate_of(res)
	if got != want {
		fail(fmt.tprintf("%s: expected SQLSTATE %s, got %s", label, want, got))
	}
}

// ddl runs a statement that must succeed.
ddl :: proc(conn: pq.Conn, sql: string, label: string) {
	res := run(conn, sql)
	defer pq.clear(res)
	st := pq.result_status(res)
	if st != .Command_OK && st != .Tuples_OK {
		fail(fmt.tprintf("%s: expected success, got %v (%s)", label, st, sqlstate_of(res)))
	}
}

main :: proc() {
	if pq.is_thread_safe() != 1 {
		fail("libpq reports a non-thread-safe build")
	}
	dsn := os.get_env("URUQUIM_TEST_DATABASE_URL", context.temp_allocator)
	if dsn == "" {
		fail("URUQUIM_TEST_DATABASE_URL is required")
	}
	dsn_c := strings.clone_to_cstring(dsn)
	defer delete_cstring(dsn_c)
	conn := pq.connectdb(dsn_c)
	if conn == nil {
		fail("libpq returned no connection")
	}
	defer pq.finish(conn)
	if pq.status(conn) != .Ok {
		fail("connection failed")
	}

	// --- SQLSTATE class 23 integrity violations ---
	ddl(conn, "CREATE TEMP TABLE lab_u (id int PRIMARY KEY)", "unique.setup")
	ddl(conn, "INSERT INTO lab_u (id) VALUES (1)", "unique.first")
	expect_sqlstate(conn, "INSERT INTO lab_u (id) VALUES (1)", "23505", "unique")

	ddl(conn, "CREATE TEMP TABLE lab_p (id int PRIMARY KEY)", "fk.parent")
	ddl(conn, "CREATE TEMP TABLE lab_c (p int REFERENCES lab_p(id))", "fk.child")
	expect_sqlstate(conn, "INSERT INTO lab_c (p) VALUES (99)", "23503", "foreign_key")

	ddl(conn, "CREATE TEMP TABLE lab_nn (v int NOT NULL)", "notnull.setup")
	expect_sqlstate(conn, "INSERT INTO lab_nn (v) VALUES (NULL)", "23502", "not_null")

	ddl(conn, "CREATE TEMP TABLE lab_chk (v int CHECK (v > 0))", "check.setup")
	expect_sqlstate(conn, "INSERT INTO lab_chk (v) VALUES (-1)", "23514", "check")

	expect_sqlstate(conn, "INSERT INTO lab_missing (v) VALUES (1)", "42P01", "undefined_table")

	// --- NULL is distinct from empty text and zero ---
	{
		res := run(conn, "SELECT NULL::text, ''::text, 0::bigint")
		defer pq.clear(res)
		if pq.result_status(res) != .Tuples_OK {
			fail("null-distinct query did not return tuples")
		}
		if !bool(pq.get_is_null(res, 0, 0)) {
			fail("column 0 (NULL) did not read as null")
		}
		if bool(pq.get_is_null(res, 0, 1)) {
			fail("column 1 (empty string) wrongly read as null")
		}
		if pq.get_length(res, 0, 1) != 0 {
			fail("empty string is not zero length")
		}
		if bool(pq.get_is_null(res, 0, 2)) {
			fail("column 2 (zero) wrongly read as null")
		}
		if string(cstring(pq.get_value(res, 0, 2))) != "0" {
			fail("zero bigint did not read as 0")
		}
	}

	// --- parameters cross the wire separately from SQL ---
	{
		payload := "'; DROP TABLE lab_u; --"
		p := strings.clone_to_cstring(payload)
		defer delete_cstring(p)
		values := [1][^]byte{transmute([^]byte)p}
		res := pq.exec_params(conn, "SELECT $1::text", 1, nil, &values[0], nil, nil, .Text)
		defer pq.clear(res)
		if pq.result_status(res) != .Tuples_OK {
			fail("parameterized echo did not return tuples")
		}
		if string(cstring(pq.get_value(res, 0, 0))) != payload {
			fail("parameter was not returned verbatim")
		}
	}

	// --- integer overflow is a client-side decode concern ---
	{
		res := run(conn, "SELECT (1099511627776)::bigint") // 2^40
		defer pq.clear(res)
		if string(cstring(pq.get_value(res, 0, 0))) != "1099511627776" {
			fail("bigint value not returned as text for client-side overflow check")
		}
	}

	// --- server-confirmed statement-timeout cancellation (SQLSTATE 57014) ---
	ddl(conn, "BEGIN", "timeout.begin")
	ddl(conn, "SET LOCAL statement_timeout = '100ms'", "timeout.set")
	expect_sqlstate(conn, "SELECT pg_sleep(2)", "57014", "statement_timeout")
	ddl(conn, "ROLLBACK", "timeout.rollback")

	// --- terminating the backend leaves an uncertain, unusable connection ---
	{
		res := run(conn, "SELECT pg_terminate_backend(pg_backend_pid())")
		pq.clear(res)
		after := run(conn, "SELECT 1")
		st := pq.result_status(after)
		pq.clear(after)
		if st != .Fatal_Error {
			fail("command after backend termination did not fail")
		}
		if pq.status(conn) != .Bad {
			fail("connection status after termination is not Bad")
		}
	}

	fmt.println("wp75-lab: integrity=ok null_distinct=ok params=ok overflow=ok timeout=57014 conn_loss=bad")
}
