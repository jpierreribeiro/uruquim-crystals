package sqlcheck

// An optional development/CI checker. It prepares each named query against a real
// migrated database and compares the parameter and result metadata PostgreSQL
// infers against the developer's declared expectations. It generates no code and
// the runtime application keeps executing explicit SQL; this only prepares and
// inspects. A statement PostgreSQL cannot prepare statically is reported as
// Unchecked, never falsely certified.

import "base:runtime"
import "core:strings"
import pg "crystals:db/postgres"

// Check declares one named query and what the developer expects of it. A negative
// expect_params or a nil expect_results disables that comparison.
Check :: struct {
	name:           string,
	sql:            string,
	expect_params:  int,      // expected parameter count; <0 to skip
	expect_results: []string, // expected result column regtype names; nil to skip
}

Finding_Kind :: enum u8 {
	Ok = 0,               // prepared, and every declared expectation matched
	Prepare_Failed,       // the query references a missing table/column or is malformed
	Param_Count_Mismatch, // the parameter count differs from the declaration
	Result_Mismatch,      // the result columns differ from the declaration
	Unchecked,            // PostgreSQL cannot statically prepare this query
}

// Finding is one check's outcome. detail is safe: a SQLSTATE or a shape summary,
// never SQL text, a bound value or a credential.
Finding :: struct {
	name:   string,
	kind:   Finding_Kind,
	detail: string,
}

Error_Kind :: enum u8 {
	None = 0,
	Db_Error,
}

Error :: struct {
	kind:   Error_Kind,
	detail: string,
	loc:    runtime.Source_Code_Location,
}

is_err :: proc "contextless" (e: Error) -> bool {
	return e.kind != .None
}

@(private)
STMT :: "_sqlcheck_stmt"

// run prepares and inspects every check against the database cfg describes, which
// the caller has already migrated. It returns one Finding per check. Findings are
// allocated in `allocator`.
run :: proc(
	cfg: pg.Config,
	checks: []Check,
	allocator := context.allocator,
	loc := #caller_location,
) -> ([]Finding, Error) {
	c, e := pg.open(cfg, loc)
	if pg.is_err(e) {
		return nil, Error{kind = .Db_Error, detail = "connection failed", loc = loc}
	}
	defer pg.close(&c)

	findings := make([]Finding, len(checks), allocator)
	for chk, i in checks {
		findings[i] = check_one(&c, chk, allocator)
	}
	return findings, Error{}
}

// has_failures reports whether any finding is a real failure. Unchecked is not a
// failure; it is an honest "cannot verify". A CI wrapper exits non-zero when this
// is true.
has_failures :: proc(findings: []Finding) -> bool {
	for f in findings {
		#partial switch f.kind {
		case .Prepare_Failed, .Param_Count_Mismatch, .Result_Mismatch:
			return true
		}
	}
	return false
}

destroy_findings :: proc(findings: []Finding, allocator := context.allocator) {
	for f in findings {
		delete(f.name, allocator)
		delete(f.detail, allocator)
	}
	delete(findings, allocator)
}

@(private)
check_one :: proc(c: ^pg.Conn, chk: Check, allocator: runtime.Allocator) -> Finding {
	f := Finding{name = strings.clone(chk.name, allocator)}

	// Deallocate any leftover from a previous check, ignoring the "not found" error.
	pg.exec_script(c, "sqlcheck.dealloc", "DEALLOCATE " + STMT)

	// PREPARE goes through the simple protocol so the query's own $N placeholders
	// are the prepared statement's parameters, not bound values.
	prepare_sql := strings.concatenate({"PREPARE ", STMT, " AS ", chk.sql}, context.temp_allocator)
	if _, pe := pg.exec_script(c, "sqlcheck.prepare", prepare_sql); pg.is_err(pe) {
		state := pg.err_sqlstate(&pe)
		if state == "42P18" || state == "0A000" {
			f.kind = .Unchecked
			f.detail = strings.clone("PostgreSQL cannot statically prepare this query", allocator)
		} else {
			f.kind = .Prepare_Failed
			f.detail = strings.clone(state, allocator)
		}
		return f
	}
	defer pg.exec_script(c, "sqlcheck.dealloc", "DEALLOCATE " + STMT)

	rows, qe := pg.query_one(
		c,
		"sqlcheck.describe",
		"SELECT coalesce(array_length(parameter_types, 1), 0), result_types::text " +
		"FROM pg_prepared_statements WHERE name = $1",
		{pg.arg_text(STMT)},
	)
	defer pg.rows_close(&rows)
	if pg.is_err(qe) {
		f.kind = .Unchecked
		f.detail = strings.clone("could not read prepared metadata", allocator)
		return f
	}
	nparams, _ := pg.row_i32(&rows, 0)
	result_text, _ := pg.row_text(&rows, 1, context.temp_allocator)
	result_types := parse_pg_array(result_text, context.temp_allocator)

	if chk.expect_params >= 0 && int(nparams) != chk.expect_params {
		f.kind = .Param_Count_Mismatch
		f.detail = strings.clone("declared parameter count does not match", allocator)
		return f
	}
	if chk.expect_results != nil && !type_lists_match(chk.expect_results, result_types) {
		f.kind = .Result_Mismatch
		f.detail = strings.clone("declared result columns do not match", allocator)
		return f
	}

	f.kind = .Ok
	f.detail = strings.clone("", allocator)
	return f
}

@(private)
parse_pg_array :: proc(s: string, allocator: runtime.Allocator) -> []string {
	inner := s
	if len(s) >= 2 && s[0] == '{' && s[len(s) - 1] == '}' {
		inner = s[1:len(s) - 1]
	}
	if len(inner) == 0 {
		return nil
	}
	return strings.split(inner, ",", allocator)
}

@(private)
type_lists_match :: proc(expected, actual: []string) -> bool {
	if len(expected) != len(actual) {
		return false
	}
	for e, i in expected {
		if e != actual[i] {
			return false
		}
	}
	return true
}
