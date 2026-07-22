package migrate

// A fail-closed PostgreSQL migration runner, deliberately separate from the HTTP
// server: the web server has no boot path that applies migrations. It composes
// the db/postgres Service Crystal for its connection, transactions and typed
// errors.
//
// WP79 freezes this contract as a RED corpus: every fallible body returns
// Error_Kind.Unimplemented so the committed tests fail for exactly one reason.
// WP80 implements the bodies and turns them green without weakening an assertion.

import "base:runtime"
import pg "crystals:db/postgres"

// Error_Kind is the migration vocabulary. It never runs at server boot and never
// reports a database "clean" when its state is uncertain.
Error_Kind :: enum u32 {
	None = 0,
	Unimplemented,

	// A migration directory or file could not be read.
	Load_Failed,
	// A filename is not <id>_<name>.up.sql / .down.sql with a positive integer id.
	Bad_Filename,
	// Two migrations declare the same id.
	Duplicate_Id,

	// An already-applied migration's file content no longer matches the recorded
	// checksum. Refused before any new DDL.
	Checksum_Mismatch,
	// An applied migration is no longer present on disk.
	Missing_Locally,

	// History contains a dirty/failed entry; further apply is refused until an
	// operator resolves it.
	Dirty_State,

	// The advisory lock could not be acquired, so another runner may be applying.
	Lock_Failed,
	// A migration's SQL failed. In transactional mode nothing partial remains; in
	// no_transaction mode the entry is recorded dirty and never clean.
	Apply_Failed,

	// An underlying db/postgres failure the runner did not classify further.
	Db_Error,
	Closed,
}

// Error carries the failure, the migration id it concerns (0 if none), a safe
// detail (never SQL text or credentials) and a source location.
Error :: struct {
	kind:   Error_Kind,
	id:     i64,
	detail: string,
	loc:    runtime.Source_Code_Location,
}

is_err :: proc "contextless" (e: Error) -> bool {
	return e.kind != .None
}

// Migration is one immutable, ordered unit of schema change loaded from disk.
// `checksum` is the SHA-256 of `up_sql`; a change to an applied migration is a
// refusal, never a silent re-run. `no_transaction` opts out of the default
// wrapping transaction for statements PostgreSQL forbids inside one (for example
// CREATE INDEX CONCURRENTLY).
Migration :: struct {
	id:             i64,
	name:           string,
	up_sql:         string,
	down_sql:       string,
	checksum:       string,
	no_transaction: bool,
}

// Migration_State is a migration's position relative to the recorded history.
Migration_State :: enum u8 {
	Pending = 0,       // on disk, not yet applied
	Applied,           // applied and checksum matches
	Dirty,             // recorded as failed/uncertain
	Checksum_Mismatch, // applied but the file changed
	Missing_Locally,   // applied but absent from disk
}

// Plan_Item is one row of `status`/dry-run output.
Plan_Item :: struct {
	id:       i64,
	name:     string,
	state:    Migration_State,
	// applied_at, duration and tool version are present for applied rows.
	applied_at:   string,
	duration_ms:  i64,
	tool_version: string,
}

// Up_Options bounds one `up` run. dry_run reports the plan without applying.
// step > 0 applies at most that many pending migrations; 0 applies all pending.
Up_Options :: struct {
	dry_run: bool,
	step:    int,
}

// Runner owns a single connection and the history bookkeeping. It is not
// thread-safe; concurrency between separate runner processes is prevented by a
// PostgreSQL advisory lock, not by sharing a Runner.
Runner :: struct {
	_conn:    pg.Conn,
	_version: string,
	_closed:  bool,
}

// load reads and validates every migration in dir: it parses ids and names,
// orders by id, rejects duplicate ids and bad filenames, reads down files when
// present, detects the no_transaction directive and computes each checksum. It
// touches no database.
//
// WP79: skeleton. WP80 implements it.
load :: proc(dir: string, allocator := context.allocator, loc := #caller_location) -> ([]Migration, Error) {
	return nil, unimpl("migrate.load", loc)
}

// open connects with cfg, ensures the history table exists, and records the tool
// version to stamp on applied rows.
//
// WP79: skeleton. WP80 implements it.
open :: proc(cfg: pg.Config, tool_version: string, loc := #caller_location) -> (Runner, Error) {
	return Runner{}, unimpl("migrate.open", loc)
}

// close releases the runner's connection exactly once.
//
// WP79: skeleton. WP80 implements it.
close :: proc(r: ^Runner) {
}

// status compares the migrations on disk against the recorded history and
// returns one Plan_Item per known id, fail-closed on checksum or missing-file
// divergence.
//
// WP79: skeleton. WP80 implements it.
status :: proc(
	r: ^Runner,
	migrations: []Migration,
	allocator := context.allocator,
	loc := #caller_location,
) -> ([]Plan_Item, Error) {
	return nil, unimpl("migrate.status", loc)
}

// up acquires the advisory lock, validates the whole history fail-closed (refusing
// dirty state, checksum mismatch and missing files), then applies pending
// migrations one at a time — each in a transaction unless no_transaction — and
// records the result atomically where PostgreSQL permits. It returns the number
// applied and releases the lock. dry_run applies nothing.
//
// WP79: skeleton. WP80 implements it.
up :: proc(
	r: ^Runner,
	migrations: []Migration,
	opts := Up_Options{},
	loc := #caller_location,
) -> (applied: int, err: Error) {
	return 0, unimpl("migrate.up", loc)
}

// down reverses the most recent applied migration using its down_sql. It is never
// presented as guaranteed data recovery: a down that has no down_sql, or whose
// down_sql cannot run, is a refusal, not a silent success.
//
// WP79: skeleton. WP80 implements it.
down :: proc(
	r: ^Runner,
	migrations: []Migration,
	opts := Up_Options{},
	loc := #caller_location,
) -> (reverted: int, err: Error) {
	return 0, unimpl("migrate.down", loc)
}

@(private)
unimpl :: proc(detail: string, loc: runtime.Source_Code_Location) -> Error {
	return Error{kind = .Unimplemented, detail = detail, loc = loc}
}
