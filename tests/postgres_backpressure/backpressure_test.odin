package postgres_backpressure_test

// WP77 backpressure corpus (authored RED by WP75, GREEN by WP77).
//
// These two cases need the bounded-operation mechanisms WP77 owns: a query
// deadline that sends a server-confirmed cancellation, and a hard field bound
// that refuses an oversized value instead of accumulating it. Until WP77
// implements them they are RED-under-control against the pinned container — the
// wrapper simply runs the query to completion, so a deadline elapses to None and
// an unbounded field decodes to None. build/check_postgres_controls.sh proves
// the RED is under control; WP77 turns them green by implementing, never by
// weakening the assertion.

import "core:testing"
import pg "crystals:db/postgres"

K :: pg.Error_Kind

test_config :: proc() -> pg.Config {
	return pg.Config{
		host            = "127.0.0.1",
		port            = 55434,
		user            = "uruquim",
		password        = "uruquim_test_pw",
		database        = "uruquim_crystals_test",
		ssl_mode        = .Disable,
		allow_plaintext = true,
	}
}

@(test)
statement_timeout_is_typed_and_cancelled :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, K.None)

	r, qe := pg.query(&c, "sleep", "SELECT pg_sleep(5)", nil, pg.Query_Opts{deadline_ms = 150})
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.Timeout)
	testing.expect_value(t, pg.err_sqlstate(&qe), "57014")
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
