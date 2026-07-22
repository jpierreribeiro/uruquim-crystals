package postgres_pool_test

// WP77 — bounded pool, acquire deadline, exhaustion and quarantine.

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

pool_config :: proc(max_conns: int, acquire_ms := 1000) -> pg.Pool_Config {
	return pg.Pool_Config{
		conn               = test_config(),
		max_conns          = max_conns,
		acquire_timeout_ms = acquire_ms,
	}
}

@(test)
pool_acquire_query_release :: proc(t: ^testing.T) {
	p, e := pg.pool_open(pool_config(4))
	defer pg.pool_close(&p)
	testing.expect_value(t, e.kind, K.None)

	c, ae := pg.acquire(&p)
	testing.expect_value(t, ae.kind, K.None)

	r, qe := pg.query_one(&c, "one", "SELECT 7::bigint")
	testing.expect_value(t, qe.kind, K.None)
	v, de := pg.row_i64(&r, 0)
	testing.expect_value(t, de.kind, K.None)
	testing.expect_value(t, v, i64(7))
	pg.rows_close(&r)

	stats := pg.pool_stats(&p)
	testing.expect_value(t, stats.in_use, 1)
	pg.release(&p, &c)
	stats = pg.pool_stats(&p)
	testing.expect_value(t, stats.in_use, 0)
	testing.expect_value(t, stats.idle, 1)
}

@(test)
min_conns_are_opened_at_boot :: proc(t: ^testing.T) {
	cfg := pool_config(4)
	cfg.min_conns = 2
	p, e := pg.pool_open(cfg)
	defer pg.pool_close(&p)
	testing.expect_value(t, e.kind, K.None)
	stats := pg.pool_stats(&p)
	testing.expect_value(t, stats.open, 2)
	testing.expect_value(t, stats.idle, 2)
}

@(test)
saturated_pool_fails_fast_and_typed :: proc(t: ^testing.T) {
	p, e := pg.pool_open(pool_config(2, 100))
	defer pg.pool_close(&p)
	testing.expect_value(t, e.kind, K.None)

	c1, e1 := pg.acquire(&p)
	testing.expect_value(t, e1.kind, K.None)
	c2, e2 := pg.acquire(&p)
	testing.expect_value(t, e2.kind, K.None)

	// The pool is full; a third acquire must return a typed exhaustion within
	// the bounded deadline, never wait forever.
	_, e3 := pg.acquire(&p)
	testing.expect_value(t, e3.kind, K.Pool_Exhausted)

	// Releasing frees capacity; the next acquire succeeds by reuse.
	pg.release(&p, &c1)
	c4, e4 := pg.acquire(&p)
	testing.expect_value(t, e4.kind, K.None)
	pg.release(&p, &c4)
	pg.release(&p, &c2)
}

@(test)
broken_connection_is_not_returned_to_the_pool :: proc(t: ^testing.T) {
	p, e := pg.pool_open(pool_config(2))
	defer pg.pool_close(&p)
	testing.expect_value(t, e.kind, K.None)

	c, ae := pg.acquire(&p)
	testing.expect_value(t, ae.kind, K.None)

	// Terminate the backend, then a command leaves the connection uncertain.
	_, _ = pg.execute(&c, "suicide", "SELECT pg_terminate_backend(pg_backend_pid())")
	_, qe := pg.execute(&c, "after", "SELECT 1")
	testing.expect_value(t, qe.kind, K.Connection_Lost)
	testing.expect(t, pg.is_broken(&c), "connection must be broken")

	pg.release(&p, &c)
	stats := pg.pool_stats(&p)
	testing.expect_value(t, stats.idle, 0) // the broken connection was discarded
	testing.expect_value(t, stats.open, 0)

	// The pool still works: a fresh connection is opened on demand.
	c2, e2 := pg.acquire(&p)
	testing.expect_value(t, e2.kind, K.None)
	r, re := pg.query_one(&c2, "ok", "SELECT 1::bigint")
	testing.expect_value(t, re.kind, K.None)
	pg.rows_close(&r)
	pg.release(&p, &c2)
}

@(test)
closed_pool_rejects_new_borrows :: proc(t: ^testing.T) {
	p, e := pg.pool_open(pool_config(2))
	testing.expect_value(t, e.kind, K.None)
	pg.pool_close(&p)

	_, ae := pg.acquire(&p)
	testing.expect_value(t, ae.kind, K.Closed)
}
