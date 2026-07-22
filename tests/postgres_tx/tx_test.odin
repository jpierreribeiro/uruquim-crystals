package postgres_tx_test

// WP78 — explicit transactions on one borrowed connection.

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

open_pool :: proc(t: ^testing.T) -> pg.Pool {
	p, e := pg.pool_open(pg.Pool_Config{conn = test_config(), max_conns = 4})
	testing.expect_value(t, e.kind, K.None)
	return p
}

// setup_table creates a fresh scratch table via a short-lived connection.
setup_table :: proc(t: ^testing.T, p: ^pg.Pool, ddl: string) {
	c, e := pg.acquire(p)
	testing.expect_value(t, e.kind, K.None)
	defer pg.release(p, &c)
	_, de := pg.execute(&c, "ddl", ddl)
	testing.expectf(t, !pg.is_err(de), "ddl failed: %v", de.kind)
}

count_rows :: proc(t: ^testing.T, p: ^pg.Pool, sql: string) -> i64 {
	c, e := pg.acquire(p)
	testing.expect_value(t, e.kind, K.None)
	defer pg.release(p, &c)
	r, qe := pg.query_one(&c, "count", sql)
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.None)
	v, _ := pg.row_i64(&r, 0)
	return v
}

@(test)
commit_persists :: proc(t: ^testing.T) {
	p := open_pool(t)
	defer pg.pool_close(&p)
	setup_table(t, &p, "DROP TABLE IF EXISTS tx_commit")
	setup_table(t, &p, "CREATE TABLE tx_commit (id bigint)")

	tx, be := pg.begin(&p)
	testing.expect_value(t, be.kind, K.None)
	_, ie := pg.tx_execute(&tx, "ins", "INSERT INTO tx_commit (id) VALUES ($1)", {pg.arg_i64(1)})
	testing.expect_value(t, ie.kind, K.None)
	ce := pg.commit(&tx)
	testing.expect_value(t, ce.kind, K.None)

	testing.expect_value(t, count_rows(t, &p, "SELECT count(*) FROM tx_commit"), i64(1))
}

@(test)
rollback_discards :: proc(t: ^testing.T) {
	p := open_pool(t)
	defer pg.pool_close(&p)
	setup_table(t, &p, "DROP TABLE IF EXISTS tx_rollback")
	setup_table(t, &p, "CREATE TABLE tx_rollback (id bigint)")

	tx, be := pg.begin(&p)
	testing.expect_value(t, be.kind, K.None)
	_, ie := pg.tx_execute(&tx, "ins", "INSERT INTO tx_rollback (id) VALUES ($1)", {pg.arg_i64(1)})
	testing.expect_value(t, ie.kind, K.None)
	re := pg.rollback(&tx)
	testing.expect_value(t, re.kind, K.None)

	testing.expect_value(t, count_rows(t, &p, "SELECT count(*) FROM tx_rollback"), i64(0))
}

@(test)
transaction_uses_one_connection :: proc(t: ^testing.T) {
	p := open_pool(t)
	defer pg.pool_close(&p)

	tx, be := pg.begin(&p)
	defer pg.rollback_if_open(&tx)
	testing.expect_value(t, be.kind, K.None)

	pid :: proc(t: ^testing.T, tx: ^pg.Tx) -> i64 {
		r, qe := pg.tx_query_one(tx, "pid", "SELECT pg_backend_pid()::bigint")
		defer pg.rows_close(&r)
		testing.expect_value(t, qe.kind, K.None)
		v, _ := pg.row_i64(&r, 0)
		return v
	}
	testing.expect_value(t, pid(t, &tx), pid(t, &tx))
}

@(test)
error_fails_the_transaction_and_rollback_if_open_recovers :: proc(t: ^testing.T) {
	p := open_pool(t)
	defer pg.pool_close(&p)

	tx, be := pg.begin(&p)
	testing.expect_value(t, be.kind, K.None)

	// A server error aborts the transaction.
	_, qe := pg.tx_execute(&tx, "bad", "INSERT INTO tx_does_not_exist VALUES (1)")
	testing.expect_value(t, qe.kind, K.Query_Failed)

	// Further work is refused until rollback.
	_, ne := pg.tx_execute(&tx, "next", "SELECT 1")
	testing.expect_value(t, ne.kind, K.Query_Failed)

	// commit on a failed transaction rolls back and reports failure.
	ce := pg.commit(&tx)
	testing.expect_value(t, ce.kind, K.Query_Failed)

	// The connection came back healthy; the pool is usable.
	stats := pg.pool_stats(&p)
	testing.expect_value(t, stats.in_use, 0)
	c, ae := pg.acquire(&p)
	defer pg.release(&p, &c)
	testing.expect_value(t, ae.kind, K.None)
}

@(test)
commit_is_idempotent_and_terminal_is_enforced :: proc(t: ^testing.T) {
	p := open_pool(t)
	defer pg.pool_close(&p)

	tx, be := pg.begin(&p)
	testing.expect_value(t, be.kind, K.None)
	testing.expect_value(t, pg.commit(&tx).kind, K.None)
	// Second commit is an idempotent no-op.
	testing.expect_value(t, pg.commit(&tx).kind, K.None)
	// rollback_if_open after commit is a safe no-op.
	pg.rollback_if_open(&tx)
	// Work after terminal is refused.
	_, ae := pg.tx_execute(&tx, "after", "SELECT 1")
	testing.expect_value(t, ae.kind, K.Closed)
}

@(test)
read_only_transaction_refuses_writes :: proc(t: ^testing.T) {
	p := open_pool(t)
	defer pg.pool_close(&p)
	setup_table(t, &p, "DROP TABLE IF EXISTS tx_ro")
	setup_table(t, &p, "CREATE TABLE tx_ro (id bigint)")

	tx, be := pg.begin(&p, pg.Tx_Options{read_only = true})
	defer pg.rollback_if_open(&tx)
	testing.expect_value(t, be.kind, K.None)

	_, ie := pg.tx_execute(&tx, "ins", "INSERT INTO tx_ro (id) VALUES (1)")
	testing.expect_value(t, ie.kind, K.Query_Failed)
	testing.expect_value(t, pg.err_sqlstate(&ie), "25006")
}

@(test)
serializable_isolation_is_applied :: proc(t: ^testing.T) {
	p := open_pool(t)
	defer pg.pool_close(&p)

	tx, be := pg.begin(&p, pg.Tx_Options{isolation = .Serializable})
	defer pg.rollback_if_open(&tx)
	testing.expect_value(t, be.kind, K.None)

	r, qe := pg.tx_query_one(&tx, "iso", "SELECT current_setting('transaction_isolation')")
	defer pg.rows_close(&r)
	testing.expect_value(t, qe.kind, K.None)
	level, de := pg.row_text(&r, 0)
	defer delete(level)
	testing.expect_value(t, de.kind, K.None)
	testing.expect_value(t, level, "serializable")
}
