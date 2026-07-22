package main

// WP79 laboratory probe. Proves that PostgreSQL advisory locks give the mutual
// exclusion the migration runner (WP80) relies on to stop two runners applying
// concurrently: a second connection cannot take a lock the first still holds,
// and can take it once the first releases. Uses the db/postgres Service Crystal
// so the probe exercises the same connection path the runner will.

import "core:fmt"
import "core:os"
import pg "crystals:db/postgres"

fail :: proc(msg: string) -> ! {
	fmt.eprintln("wp79-lock:", msg)
	os.exit(1)
}

try_lock :: proc(c: ^pg.Conn, key: i64) -> bool {
	r, e := pg.query_one(c, "try_lock", "SELECT pg_try_advisory_lock($1)", {pg.arg_i64(key)})
	defer pg.rows_close(&r)
	if pg.is_err(e) {
		fail("try_advisory_lock query failed")
	}
	got, de := pg.row_bool(&r, 0)
	if pg.is_err(de) {
		fail("try_advisory_lock did not decode as bool")
	}
	return got
}

main :: proc() {
	cfg := pg.Config {
		host            = "127.0.0.1",
		port            = 55434,
		user            = "uruquim",
		password        = "uruquim_test_pw",
		database        = "uruquim_crystals_test",
		ssl_mode        = .Disable,
		allow_plaintext = true,
	}
	c1, e1 := pg.open(cfg)
	defer pg.close(&c1)
	c2, e2 := pg.open(cfg)
	defer pg.close(&c2)
	if pg.is_err(e1) || pg.is_err(e2) {
		fail("could not open two connections")
	}

	KEY :: i64(424242)
	if !try_lock(&c1, KEY) {
		fail("first connection failed to take a free lock")
	}
	if try_lock(&c2, KEY) {
		fail("second connection took a lock the first still holds")
	}
	if _, ue := pg.execute(&c1, "unlock", "SELECT pg_advisory_unlock($1)", {pg.arg_i64(KEY)}); pg.is_err(ue) {
		fail("unlock failed")
	}
	if !try_lock(&c2, KEY) {
		fail("second connection could not take the released lock")
	}

	fmt.println("wp79-lock: exclusive=ok released=ok")
}
