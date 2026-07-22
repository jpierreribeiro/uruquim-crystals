package postgres_test

// WP75 — PostgreSQL wire/error laboratory (RED corpus).
//
// These tests are written against the real db/postgres contract and run against
// the pinned disposable PostgreSQL 16 container. Until WP76+ implement the
// wrapper bodies they are RED-under-control: every fallible call returns
// Error_Kind.Unimplemented, so each contract assertion fails with a single,
// diagnosable reason. build/check_wp75_controls.sh proves that. No assertion
// below accepts Unimplemented; WP76 (execution, decoding, SQLSTATE mapping),
// WP77 (timeout, cancellation, bounds) and WP78 turn them green by
// implementing, never by weakening the corpus.

import "core:testing"
import pg "crystals:db/postgres"

K :: pg.Error_Kind

// exec_ddl runs a schema statement and asserts it succeeded, so a later
// contract assertion is not masked by broken setup.
@(private = "file")
exec_ddl :: proc(t: ^testing.T, c: ^pg.Conn, sql: string) {
	_, e := pg.execute(c, "ddl", sql)
	testing.expectf(t, !pg.is_err(e), "ddl failed: kind=%v", e.kind)
}

// --- connection, authentication and TLS policy ---

@(test)
connect_succeeds_with_the_pinned_profile :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	r, qe := pg.query_one(&c, "select.one", "SELECT 1::bigint")
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.None)
	v, de := pg.row_i64(&r, 0)
	testing.expect_value(t, de.kind, K.None)
	testing.expect_value(t, v, i64(1))
}

@(test)
wrong_password_is_auth_failed :: proc(t: ^testing.T) {
	cfg := test_config()
	cfg.password = "wp75_deliberately_wrong"
	c, e := pg.open(cfg)
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.Auth_Failed)
}

@(test)
plaintext_without_optin_is_config_invalid :: proc(t: ^testing.T) {
	cfg := test_config()
	cfg.allow_plaintext = false // Disable must be explicitly opted into
	c, e := pg.open(cfg)
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.Config_Invalid)
}

// --- parameters are never SQL structure ---

@(test)
parameters_cannot_become_sql :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	// A classic injection payload must return as an ordinary text value, not
	// execute. If it were interpolated, the statement would error or drop.
	payload := "'; DROP TABLE wp75_victim; --"
	r, qe := pg.query_one(&c, "echo", "SELECT $1::text", {pg.arg_text(payload)})
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.None)
	got, de := pg.row_text(&r, 0)
	defer delete(got)
	testing.expect_value(t, de.kind, K.None)
	testing.expect_value(t, got, payload)
}

// --- SQLSTATE class 23 integrity violations map to typed kinds ---

@(test)
unique_violation_is_typed :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	exec_ddl(t, &c, "DROP TABLE IF EXISTS wp75_unique")
	exec_ddl(t, &c, "CREATE TABLE wp75_unique (id bigint PRIMARY KEY)")
	_, e1 := pg.execute(&c, "u.insert", "INSERT INTO wp75_unique (id) VALUES ($1)", {pg.arg_i64(1)})
	testing.expect_value(t, e1.kind, K.None)
	_, e2 := pg.execute(&c, "u.insert", "INSERT INTO wp75_unique (id) VALUES ($1)", {pg.arg_i64(1)})
	testing.expect_value(t, e2.kind, K.Unique_Violation)
	testing.expect_value(t, pg.err_sqlstate(&e2), "23505")
}

@(test)
foreign_key_violation_is_typed :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	exec_ddl(t, &c, "DROP TABLE IF EXISTS wp75_child")
	exec_ddl(t, &c, "DROP TABLE IF EXISTS wp75_parent")
	exec_ddl(t, &c, "CREATE TABLE wp75_parent (id bigint PRIMARY KEY)")
	exec_ddl(t, &c, "CREATE TABLE wp75_child (parent bigint REFERENCES wp75_parent(id))")
	_, ie := pg.execute(&c, "c.insert", "INSERT INTO wp75_child (parent) VALUES ($1)", {pg.arg_i64(99)})
	testing.expect_value(t, ie.kind, K.Foreign_Key_Violation)
	testing.expect_value(t, pg.err_sqlstate(&ie), "23503")
}

@(test)
not_null_violation_is_typed :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	exec_ddl(t, &c, "DROP TABLE IF EXISTS wp75_nn")
	exec_ddl(t, &c, "CREATE TABLE wp75_nn (v bigint NOT NULL)")
	_, ie := pg.execute(&c, "nn.insert", "INSERT INTO wp75_nn (v) VALUES ($1)", {pg.arg_null()})
	testing.expect_value(t, ie.kind, K.Not_Null_Violation)
	testing.expect_value(t, pg.err_sqlstate(&ie), "23502")
}

@(test)
check_violation_is_typed :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	exec_ddl(t, &c, "DROP TABLE IF EXISTS wp75_chk")
	exec_ddl(t, &c, "CREATE TABLE wp75_chk (v bigint CHECK (v > 0))")
	_, ie := pg.execute(&c, "chk.insert", "INSERT INTO wp75_chk (v) VALUES ($1)", {pg.arg_i64(-1)})
	testing.expect_value(t, ie.kind, K.Check_Violation)
	testing.expect_value(t, pg.err_sqlstate(&ie), "23514")
}

@(test)
undefined_table_preserves_sqlstate :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	_, qe := pg.execute(&c, "missing", "INSERT INTO wp75_does_not_exist (v) VALUES (1)")
	testing.expect_value(t, qe.kind, K.Query_Failed)
	testing.expect_value(t, pg.err_sqlstate(&qe), "42P01")
}

// --- NULL, empty and zero remain distinct ---

@(test)
null_is_distinct_from_empty_and_zero :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	r, qe := pg.query_one(&c, "nulls", "SELECT NULL::text, ''::text, 0::bigint")
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.None)

	is_null, ne := pg.row_is_null(&r, 0)
	testing.expect_value(t, ne.kind, K.None)
	testing.expect(t, is_null, "column 0 must read as NULL")

	empty, ee := pg.row_opt_text(&r, 1)
	testing.expect_value(t, ee.kind, K.None)
	s, has := empty.?
	testing.expect(t, has, "empty string must be present, not NULL")
	testing.expect_value(t, s, "")

	zero, ze := pg.row_opt_i64(&r, 2)
	testing.expect_value(t, ze.kind, K.None)
	z, hasz := zero.?
	testing.expect(t, hasz, "zero must be present, not NULL")
	testing.expect_value(t, z, i64(0))
}

@(test)
null_into_non_optional_fails_closed :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	r, qe := pg.query_one(&c, "null.bigint", "SELECT NULL::bigint")
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.None)
	_, de := pg.row_i64(&r, 0)
	testing.expect_value(t, de.kind, K.Decode_Null)
}

// --- decode is fail-closed on mismatch and overflow ---

@(test)
type_mismatch_fails_closed :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	r, qe := pg.query_one(&c, "text.as.int", "SELECT 'not a number'::text")
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.None)
	_, de := pg.row_i64(&r, 0)
	testing.expect_value(t, de.kind, K.Decode_Type_Mismatch)
}

@(test)
integer_overflow_fails_closed :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	// 2^40 does not fit an i32.
	r, qe := pg.query_one(&c, "overflow", "SELECT (1099511627776)::bigint")
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.None)
	_, de := pg.row_i32(&r, 0)
	testing.expect_value(t, de.kind, K.Decode_Overflow)
}

@(test)
unknown_column_name_is_shape_error :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	r, qe := pg.query_one(&c, "one.col", "SELECT 1 AS present")
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.None)
	_, ce := pg.column(&r, "absent")
	testing.expect_value(t, ce.kind, K.Decode_Shape)
}

// --- query_one cardinality ---

@(test)
query_one_zero_rows_is_not_found :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	r, qe := pg.query_one(&c, "empty", "SELECT 1 WHERE false")
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.Row_Not_Found)
}

@(test)
query_one_many_rows_is_too_many :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	r, qe := pg.query_one(&c, "two", "SELECT * FROM (VALUES (1),(2)) AS s(v)")
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.Too_Many_Rows)
}

// --- timeout, cancellation, connection loss and bounds (flip in WP77) ---

@(test)
statement_timeout_is_typed_and_cancelled :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	_, qe := pg.query(&c, "sleep", "SELECT pg_sleep(5)", nil, pg.Query_Opts{deadline_ms = 150})
	testing.expect_value(t, qe.kind, K.Timeout)
	testing.expect_value(t, pg.err_sqlstate(&qe), "57014")
}

@(test)
connection_loss_mid_query_quarantines :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	// Terminating our own backend makes the next command fail with an uncertain
	// physical state. The connection must be marked broken, never pooled.
	_, _ = pg.execute(&c, "suicide", "SELECT pg_terminate_backend(pg_backend_pid())")
	_, qe := pg.execute(&c, "after", "SELECT 1")
	testing.expect_value(t, qe.kind, K.Connection_Lost)
	testing.expect(t, pg.is_broken(&c), "a lost connection must be marked broken")
}

@(test)
oversized_field_is_bounded :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	opts := pg.Query_Opts{max_field_bytes = 1024}
	r, qe := pg.query_one(&c, "big", "SELECT repeat('x', 100000)", nil, opts)
	defer pg.rows_close(&r)
	// Either the query call or the decode must refuse; the wrapper never
	// accumulates an unbounded field.
	if qe.kind == K.None {
		_, de := pg.row_text(&r, 0)
		testing.expect_value(t, de.kind, K.Result_Too_Large)
	} else {
		testing.expect_value(t, qe.kind, K.Result_Too_Large)
	}
}

@(test)
closed_connection_rejects_operations :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	testing.expect_value(t, e.kind, K.None)
	pg.close(&c)
	_, qe := pg.execute(&c, "after.close", "SELECT 1")
	testing.expect_value(t, qe.kind, K.Closed)
}
