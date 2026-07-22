package postgres_test

// Query deadline/cancellation and result bounds (WP75 authored RED, WP77 GREEN).
// A per-query deadline sends a server-confirmed cancellation; a field bound
// refuses an oversized value instead of exposing it.

import "core:testing"
import pg "crystals:db/postgres"

@(test)
statement_timeout_is_typed_and_cancelled :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	r, qe := pg.query(&c, "sleep", "SELECT pg_sleep(5)", nil, pg.Query_Opts{deadline_ms = 150})
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.Timeout)
	testing.expect_value(t, pg.err_sqlstate(&qe), "57014")
	// A cancelled query that finished with 57014 leaves the connection usable.
	testing.expect(t, !pg.is_broken(&c), "a cleanly cancelled query must not quarantine the connection")
}

@(test)
oversized_field_is_bounded :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	opts := pg.Query_Opts{max_field_bytes = 1024}
	r, qe := pg.query_one(&c, "big", "SELECT repeat('x', 100000)", nil, opts)
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.Result_Too_Large)
}

@(test)
row_bound_refuses_excess_rows :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	opts := pg.Query_Opts{max_rows = 2}
	r, qe := pg.query(&c, "series", "SELECT g FROM generate_series(1, 100) AS g", nil, opts)
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.Result_Too_Large)
}
