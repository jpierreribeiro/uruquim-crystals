package postgres_test

// exec_script runs a trusted multi-statement DDL script (no parameters).

import "core:testing"
import pg "crystals:db/postgres"

@(test)
exec_script_runs_multiple_statements :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	_, se := pg.exec_script(
		&c,
		"script",
		"CREATE TEMP TABLE script_t (id bigint); INSERT INTO script_t VALUES (1); INSERT INTO script_t VALUES (2);",
	)
	testing.expect_value(t, se.kind, K.None)

	r, qe := pg.query_one(&c, "count", "SELECT count(*) FROM script_t")
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.None)
	v, _ := pg.row_i64(&r, 0)
	testing.expect_value(t, v, i64(2))
}

@(test)
exec_script_reports_a_failed_statement :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	_, se := pg.exec_script(&c, "bad_script", "SELECT 1; SELECT * FROM script_does_not_exist;")
	testing.expect_value(t, se.kind, K.Query_Failed)
	testing.expect_value(t, pg.err_sqlstate(&se), "42P01")
}
