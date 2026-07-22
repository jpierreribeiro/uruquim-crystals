package sqlcheck_test

import "core:path/filepath"
import "core:testing"
import mig "crystals:db/migrate"
import pg "crystals:db/postgres"
import sc "crystals:db/sqlcheck"

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

// setup creates the schema the checks run against, directly.
setup :: proc(t: ^testing.T) {
	c, e := pg.open(test_config())
	defer pg.close(&c)
	testing.expect_value(t, e.kind, pg.Error_Kind.None)
	_, _ = pg.execute(&c, "reset", "DROP TABLE IF EXISTS sc_widgets")
	_, ce := pg.execute(&c, "create", "CREATE TABLE sc_widgets (id bigint PRIMARY KEY, name text)")
	testing.expectf(t, !pg.is_err(ce), "create failed: %v", ce.kind)
}

find :: proc(findings: []sc.Finding, name: string) -> sc.Finding {
	for f in findings {
		if f.name == name {
			return f
		}
	}
	return sc.Finding{}
}

@(test)
checker_classifies_each_query :: proc(t: ^testing.T) {
	setup(t)
	checks := []sc.Check{
		{name = "good", sql = "SELECT id, name FROM sc_widgets WHERE id = $1", expect_params = 1, expect_results = {"bigint", "text"}},
		{name = "missing_column", sql = "SELECT nope FROM sc_widgets", expect_params = 0},
		{name = "param_mismatch", sql = "SELECT id FROM sc_widgets WHERE id = $1", expect_params = 2},
		{name = "result_mismatch", sql = "SELECT id FROM sc_widgets", expect_results = {"text"}},
		{name = "unchecked", sql = "SELECT $1 IS NULL", expect_params = 1},
	}

	findings, e := sc.run(test_config(), checks)
	defer sc.destroy_findings(findings)
	testing.expect_value(t, e.kind, sc.Error_Kind.None)
	testing.expect_value(t, len(findings), 5)

	testing.expect_value(t, find(findings, "good").kind, sc.Finding_Kind.Ok)
	testing.expect_value(t, find(findings, "missing_column").kind, sc.Finding_Kind.Prepare_Failed)
	testing.expect_value(t, find(findings, "param_mismatch").kind, sc.Finding_Kind.Param_Count_Mismatch)
	testing.expect_value(t, find(findings, "result_mismatch").kind, sc.Finding_Kind.Result_Mismatch)
	testing.expect_value(t, find(findings, "unchecked").kind, sc.Finding_Kind.Unchecked)
}

@(test)
has_failures_ignores_unchecked_and_ok :: proc(t: ^testing.T) {
	setup(t)
	clean := []sc.Check{
		{name = "good", sql = "SELECT id FROM sc_widgets", expect_results = {"bigint"}},
		{name = "unchecked", sql = "SELECT $1 IS NULL", expect_params = 1},
	}
	f1, _ := sc.run(test_config(), clean)
	defer sc.destroy_findings(f1)
	testing.expect(t, !sc.has_failures(f1), "Ok and Unchecked are not failures")

	broken := []sc.Check{{name = "bad", sql = "SELECT x FROM sc_widgets"}}
	f2, _ := sc.run(test_config(), broken)
	defer sc.destroy_findings(f2)
	testing.expect(t, sc.has_failures(f2), "a Prepare_Failed is a failure")
}

// The full workflow: apply migrations, then check queries against the schema they
// produced.
@(test)
checks_run_against_a_migrated_schema :: proc(t: ^testing.T) {
	// reset history and schema
	{
		c, _ := pg.open(test_config())
		defer pg.close(&c)
		_, _ = pg.execute(&c, "reset", "DROP TABLE IF EXISTS _uruquim_migrations")
		_, _ = pg.execute(&c, "reset", "DROP TABLE IF EXISTS mig_widgets")
	}
	dir, _ := filepath.join({filepath.dir(#file), "..", "migrate", "fixtures", "ok"}, context.temp_allocator)
	ms, le := mig.load(dir)
	defer mig.destroy_migrations(ms)
	testing.expect_value(t, le.kind, mig.Error_Kind.None)

	r, oe := mig.open(test_config(), "sqlcheck-test")
	defer mig.close(&r)
	testing.expect_value(t, oe.kind, mig.Error_Kind.None)
	_, ue := mig.up(&r, ms)
	testing.expect_value(t, ue.kind, mig.Error_Kind.None)

	checks := []sc.Check{
		{name = "by_id", sql = "SELECT id, name FROM mig_widgets WHERE id = $1", expect_params = 1, expect_results = {"bigint", "text"}},
	}
	findings, _ := sc.run(test_config(), checks)
	defer sc.destroy_findings(findings)
	testing.expect_value(t, find(findings, "by_id").kind, sc.Finding_Kind.Ok)
}
