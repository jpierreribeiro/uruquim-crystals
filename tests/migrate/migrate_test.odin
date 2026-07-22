package migrate_test

// WP79 — migration contract, committed RED. Every assertion states the real
// fail-closed contract; until WP80 implements the runner the calls return
// Error_Kind.Unimplemented, so the corpus is RED-under-control. No assertion
// accepts the sentinel.

import "core:path/filepath"
import "core:testing"
import mig "crystals:db/migrate"
import pg "crystals:db/postgres"

MK :: mig.Error_Kind

fixture :: proc(name: string) -> string {
	p, _ := filepath.join({filepath.dir(#file), "fixtures", name}, context.temp_allocator)
	return p
}

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

// reset drops the history and fixture tables so each DB test starts clean.
reset :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, pg.Error_Kind.None)
	for sql in ([]string{
		"DROP TABLE IF EXISTS _uruquim_migrations",
		"DROP INDEX IF EXISTS mig_widgets_name_idx",
		"DROP TABLE IF EXISTS mig_widgets",
		"DROP TABLE IF EXISTS mig_bad",
		"DROP TABLE IF EXISTS mig_a",
		"DROP TABLE IF EXISTS mig_b",
		"DROP TABLE IF EXISTS mig_multi",
	}) {
		_, _ = pg.execute(&c, "reset", sql)
	}
}

@(test)
multi_statement_migration_applies :: proc(t: ^testing.T) {
	reset(t)
	r, _ := mig.open(test_config(), "wp79-test")
	defer mig.close(&r)
	ms, _ := mig.load(fixture("multi"))
	defer mig.destroy_migrations(ms)

	n, e := mig.up(&r, ms)
	testing.expect_value(t, e.kind, MK.None)
	testing.expect_value(t, n, 1)

	// The second statement in the file ran too.
	c, _ := pg.open(test_config())
	defer pg.close(&c)
	rows, _ := pg.query_one(&c, "count", "SELECT count(*) FROM mig_multi")
	defer pg.rows_close(&rows)
	v, _ := pg.row_i64(&rows, 0)
	testing.expect_value(t, v, i64(1))
}

@(test)
no_transaction_failure_is_recorded_dirty :: proc(t: ^testing.T) {
	reset(t)
	r, _ := mig.open(test_config(), "wp79-test")
	defer mig.close(&r)
	ms, _ := mig.load(fixture("notx_fail"))
	defer mig.destroy_migrations(ms)
	testing.expect(t, ms[0].no_transaction, "fixture must be no_transaction")

	_, ue := mig.up(&r, ms)
	testing.expect_value(t, ue.kind, MK.Apply_Failed)

	// A failed no_transaction migration is recorded dirty; the next run refuses.
	_, de := mig.up(&r, ms)
	testing.expect_value(t, de.kind, MK.Dirty_State)
}

// --- load: pure, no database ---

@(test)
load_orders_and_checksums :: proc(t: ^testing.T) {
	ms, e := mig.load(fixture("ok"))
	defer mig.destroy_migrations(ms)
	testing.expect_value(t, e.kind, MK.None)
	testing.expect_value(t, len(ms), 3)
	testing.expect_value(t, ms[0].id, i64(1))
	testing.expect_value(t, ms[1].id, i64(2))
	testing.expect_value(t, ms[2].id, i64(3))
	testing.expect(t, ms[0].checksum != "", "checksum must be computed")
	testing.expect(t, ms[0].checksum != ms[1].checksum, "checksums must differ")
	testing.expect(t, ms[0].down_sql != "", "down file must be loaded")
}

@(test)
load_rejects_duplicate_ids :: proc(t: ^testing.T) {
	_, e := mig.load(fixture("dup"))
	testing.expect_value(t, e.kind, MK.Duplicate_Id)
}

@(test)
load_parses_no_transaction :: proc(t: ^testing.T) {
	ms, e := mig.load(fixture("notx"))
	defer mig.destroy_migrations(ms)
	testing.expect_value(t, e.kind, MK.None)
	testing.expect_value(t, len(ms), 1)
	testing.expect(t, ms[0].no_transaction, "the no_transaction directive must be parsed")
}

// --- up / status / dirty / checksum: against the pinned database ---

@(test)
up_applies_pending_and_status_reports_applied :: proc(t: ^testing.T) {
	reset(t)
	r, oe := mig.open(test_config(), "wp79-test")
	defer mig.close(&r)
	testing.expect_value(t, oe.kind, MK.None)

	ms, le := mig.load(fixture("ok"))
	defer mig.destroy_migrations(ms)
	testing.expect_value(t, le.kind, MK.None)

	n, ue := mig.up(&r, ms)
	testing.expect_value(t, ue.kind, MK.None)
	testing.expect_value(t, n, 3)

	plan, se := mig.status(&r, ms)
	defer mig.destroy_plan(plan)
	testing.expect_value(t, se.kind, MK.None)
	testing.expect_value(t, len(plan), 3)
	for item in plan {
		testing.expect_value(t, item.state, mig.Migration_State.Applied)
		testing.expect(t, item.tool_version == "wp79-test", "applied rows carry the tool version")
	}
}

@(test)
up_is_idempotent :: proc(t: ^testing.T) {
	reset(t)
	r, _ := mig.open(test_config(), "wp79-test")
	defer mig.close(&r)
	ms, _ := mig.load(fixture("ok"))
	defer mig.destroy_migrations(ms)

	n1, e1 := mig.up(&r, ms)
	testing.expect_value(t, e1.kind, MK.None)
	testing.expect_value(t, n1, 3)
	n2, e2 := mig.up(&r, ms)
	testing.expect_value(t, e2.kind, MK.None)
	testing.expect_value(t, n2, 0)
}

@(test)
dry_run_applies_nothing :: proc(t: ^testing.T) {
	reset(t)
	r, _ := mig.open(test_config(), "wp79-test")
	defer mig.close(&r)
	ms, _ := mig.load(fixture("ok"))
	defer mig.destroy_migrations(ms)

	n, e := mig.up(&r, ms, mig.Up_Options{dry_run = true})
	testing.expect_value(t, e.kind, MK.None)
	testing.expect_value(t, n, 0)

	plan, _ := mig.status(&r, ms)
	defer mig.destroy_plan(plan)
	for item in plan {
		testing.expect_value(t, item.state, mig.Migration_State.Pending)
	}
}

@(test)
changed_applied_migration_is_refused :: proc(t: ^testing.T) {
	reset(t)
	r, _ := mig.open(test_config(), "wp79-test")
	defer mig.close(&r)

	ok_ms, _ := mig.load(fixture("ok"))
	defer mig.destroy_migrations(ok_ms)
	_, ue := mig.up(&r, ok_ms)
	testing.expect_value(t, ue.kind, MK.None)

	// The same id 1 with different content must be refused before any new DDL.
	changed_ms, _ := mig.load(fixture("changed"))
	defer mig.destroy_migrations(changed_ms)
	_, ce := mig.up(&r, changed_ms)
	testing.expect_value(t, ce.kind, MK.Checksum_Mismatch)
}

@(test)
failing_migration_rolls_back_and_then_refuses_dirty :: proc(t: ^testing.T) {
	reset(t)
	r, _ := mig.open(test_config(), "wp79-test")
	defer mig.close(&r)

	ms, _ := mig.load(fixture("bad"))
	defer mig.destroy_migrations(ms)
	_, ue := mig.up(&r, ms)
	testing.expect_value(t, ue.kind, MK.Apply_Failed)

	// The first migration committed in its own transaction; the second rolled
	// back. A second run must refuse the recorded dirty state, never report the
	// database clean.
	_, de := mig.up(&r, ms)
	testing.expect_value(t, de.kind, MK.Dirty_State)
}

@(test)
down_reverts_the_last_applied :: proc(t: ^testing.T) {
	reset(t)
	r, _ := mig.open(test_config(), "wp79-test")
	defer mig.close(&r)
	ms, _ := mig.load(fixture("ok"))
	defer mig.destroy_migrations(ms)

	_, ue := mig.up(&r, ms)
	testing.expect_value(t, ue.kind, MK.None)

	n, dn := mig.down(&r, ms)
	testing.expect_value(t, dn.kind, MK.None)
	testing.expect_value(t, n, 1)

	plan, _ := mig.status(&r, ms)
	defer mig.destroy_plan(plan)
	testing.expect_value(t, plan[0].state, mig.Migration_State.Applied)
	testing.expect_value(t, plan[1].state, mig.Migration_State.Applied)
	testing.expect_value(t, plan[2].state, mig.Migration_State.Pending)
}
