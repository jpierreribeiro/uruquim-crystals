package migrate

import "base:runtime"
import "core:strings"
import "core:time"
import pg "crystals:db/postgres"

// A fixed advisory-lock key so any two runners contend for the same lock.
@(private)
LOCK_KEY :: i64(0x7572_7571_5f6d_6967)

@(private)
HISTORY_DDL ::
	"CREATE TABLE IF NOT EXISTS _uruquim_migrations (" +
	"id bigint PRIMARY KEY, name text NOT NULL, checksum text NOT NULL, " +
	"applied_at timestamptz NOT NULL DEFAULT now(), duration_ms bigint NOT NULL, " +
	"tool_version text NOT NULL, dirty boolean NOT NULL DEFAULT false)"

@(private)
History :: struct {
	checksum:     string,
	dirty:        bool,
	tool_version: string,
	duration_ms:  i64,
	applied_at:   string,
}

// open connects with cfg, ensures the history table exists, and records the tool
// version to stamp on applied rows.
open :: proc(cfg: pg.Config, tool_version: string, loc := #caller_location) -> (Runner, Error) {
	c, e := pg.open(cfg, loc)
	if pg.is_err(e) {
		return Runner{}, mig_err(.Db_Error, 0, "connection failed", loc)
	}
	if _, he := pg.execute(&c, "migrate.history", HISTORY_DDL); pg.is_err(he) {
		// CREATE TABLE IF NOT EXISTS is not fully race-safe in PostgreSQL: two
		// runners starting together can collide on the catalog. A duplicate-table
		// or duplicate-key from that race means the table now exists, which is
		// exactly the desired outcome.
		ss := pg.err_sqlstate(&he)
		if ss != "42P07" && ss != "23505" {
			pg.close(&c)
			return Runner{}, mig_err(.Db_Error, 0, "could not ensure history table", loc)
		}
	}
	return Runner{_conn = c, _version = strings.clone(tool_version)}, Error{}
}

// destroy_migrations frees the strings and slice load allocated.
destroy_migrations :: proc(ms: []Migration, allocator := context.allocator) {
	for m in ms {
		delete(m.name, allocator)
		delete(m.up_sql, allocator)
		delete(m.down_sql, allocator)
		delete(m.checksum, allocator)
	}
	delete(ms, allocator)
}

// destroy_plan frees the strings and slice status allocated.
destroy_plan :: proc(items: []Plan_Item, allocator := context.allocator) {
	for it in items {
		delete(it.name, allocator)
		delete(it.tool_version, allocator)
		delete(it.applied_at, allocator)
	}
	delete(items, allocator)
}

// close releases the runner's connection exactly once.
close :: proc(r: ^Runner) {
	if !r._closed {
		pg.close(&r._conn)
		delete(r._version)
		r._closed = true
	}
}

// status compares the migrations on disk against the recorded history and
// returns one Plan_Item per migration, fail-closed on checksum divergence.
status :: proc(
	r: ^Runner,
	migrations: []Migration,
	allocator := context.allocator,
	loc := #caller_location,
) -> ([]Plan_Item, Error) {
	hist, he := read_history(r, context.temp_allocator, loc)
	if is_err(he) {
		return nil, he
	}

	items := make([dynamic]Plan_Item, allocator)
	for m in migrations {
		item := Plan_Item{id = m.id, name = strings.clone(m.name, allocator)}
		if h, ok := hist[m.id]; ok {
			switch {
			case h.dirty:
				item.state = .Dirty
			case h.checksum != m.checksum:
				item.state = .Checksum_Mismatch
			case:
				item.state = .Applied
			}
			item.tool_version = strings.clone(h.tool_version, allocator)
			item.applied_at = strings.clone(h.applied_at, allocator)
			item.duration_ms = h.duration_ms
		} else {
			item.state = .Pending
		}
		append(&items, item)
	}
	return items[:], Error{}
}

// up acquires the advisory lock, validates the whole history fail-closed, then
// applies pending migrations one at a time and records each result. dry_run
// applies nothing. It returns the number applied.
up :: proc(
	r: ^Runner,
	migrations: []Migration,
	opts := Up_Options{},
	loc := #caller_location,
) -> (applied: int, err: Error) {
	if r._closed {
		return 0, mig_err(.Closed, 0, "runner is closed", loc)
	}
	got, le := lock(r, loc)
	if is_err(le) {
		return 0, le
	}
	if !got {
		return 0, mig_err(.Lock_Failed, 0, "another runner holds the migration lock", loc)
	}
	defer unlock(r)

	hist, he := read_history(r, context.temp_allocator, loc)
	if is_err(he) {
		return 0, he
	}

	// Fail-closed validation before any DDL: no dirty state, no changed checksum.
	for m in migrations {
		if h, ok := hist[m.id]; ok {
			if h.dirty {
				return 0, mig_err(.Dirty_State, m.id, "history has a dirty migration", loc)
			}
			if h.checksum != m.checksum {
				return 0, mig_err(.Checksum_Mismatch, m.id, "applied migration changed on disk", loc)
			}
		}
	}

	for m in migrations {
		if _, ok := hist[m.id]; ok {
			continue // already applied
		}
		if opts.step > 0 && applied >= opts.step {
			break
		}
		if opts.dry_run {
			continue
		}
		if ae := apply_one(r, m, loc); is_err(ae) {
			return applied, ae
		}
		applied += 1
	}
	return applied, Error{}
}

// down reverts the most recently applied migrations (up to step, default one)
// using their down SQL. A migration without down SQL, or missing from disk, is a
// refusal — down is never presented as guaranteed recovery.
down :: proc(
	r: ^Runner,
	migrations: []Migration,
	opts := Up_Options{},
	loc := #caller_location,
) -> (reverted: int, err: Error) {
	if r._closed {
		return 0, mig_err(.Closed, 0, "runner is closed", loc)
	}
	got, le := lock(r, loc)
	if is_err(le) {
		return 0, le
	}
	if !got {
		return 0, mig_err(.Lock_Failed, 0, "another runner holds the migration lock", loc)
	}
	defer unlock(r)

	hist, he := read_history(r, context.temp_allocator, loc)
	if is_err(he) {
		return 0, he
	}

	steps := opts.step if opts.step > 0 else 1
	// Walk migrations from highest id down, reverting applied ones.
	#reverse for m in migrations {
		if reverted >= steps {
			break
		}
		h, ok := hist[m.id]
		if !ok {
			continue // not applied
		}
		if h.dirty {
			return reverted, mig_err(.Dirty_State, m.id, "cannot revert past a dirty migration", loc)
		}
		if m.down_sql == "" {
			return reverted, mig_err(.Apply_Failed, m.id, "migration has no down SQL", loc)
		}
		if opts.dry_run {
			reverted += 1
			continue
		}
		if re := revert_one(r, m, loc); is_err(re) {
			return reverted, re
		}
		reverted += 1
	}
	return reverted, Error{}
}

// --- private plumbing ---

@(private)
apply_one :: proc(r: ^Runner, m: Migration, loc: runtime.Source_Code_Location) -> Error {
	start := time.now()

	if m.no_transaction {
		_, e := pg.exec_script(&r._conn, m.name, m.up_sql)
		dur := ms_since(start)
		if pg.is_err(e) {
			// The statement may have partially applied; record dirty so the
			// database is never reported clean.
			record(r, m, dur, true, loc)
			return mig_err(.Apply_Failed, m.id, "no_transaction migration failed", loc)
		}
		return record(r, m, dur, false, loc)
	}

	if _, be := pg.execute(&r._conn, "begin", "BEGIN"); pg.is_err(be) {
		return mig_err(.Db_Error, m.id, "could not open transaction", loc)
	}
	if _, e := pg.exec_script(&r._conn, m.name, m.up_sql); pg.is_err(e) {
		pg.execute(&r._conn, "rollback", "ROLLBACK")
		record(r, m, ms_since(start), true, loc) // dirty marker, outside the tx
		return mig_err(.Apply_Failed, m.id, "migration failed", loc)
	}
	if re := record(r, m, ms_since(start), false, loc); is_err(re) {
		pg.execute(&r._conn, "rollback", "ROLLBACK")
		record(r, m, ms_since(start), true, loc)
		return re
	}
	if _, ce := pg.execute(&r._conn, "commit", "COMMIT"); pg.is_err(ce) {
		record(r, m, ms_since(start), true, loc)
		return mig_err(.Apply_Failed, m.id, "commit failed", loc)
	}
	return Error{}
}

@(private)
revert_one :: proc(r: ^Runner, m: Migration, loc: runtime.Source_Code_Location) -> Error {
	if _, be := pg.execute(&r._conn, "begin", "BEGIN"); pg.is_err(be) {
		return mig_err(.Db_Error, m.id, "could not open transaction", loc)
	}
	if _, e := pg.exec_script(&r._conn, m.name, m.down_sql); pg.is_err(e) {
		pg.execute(&r._conn, "rollback", "ROLLBACK")
		return mig_err(.Apply_Failed, m.id, "down migration failed", loc)
	}
	if _, de := pg.execute(&r._conn, "unrecord", "DELETE FROM _uruquim_migrations WHERE id = $1", {pg.arg_i64(m.id)}); pg.is_err(de) {
		pg.execute(&r._conn, "rollback", "ROLLBACK")
		return mig_err(.Db_Error, m.id, "could not update history", loc)
	}
	if _, ce := pg.execute(&r._conn, "commit", "COMMIT"); pg.is_err(ce) {
		return mig_err(.Db_Error, m.id, "commit failed", loc)
	}
	return Error{}
}

@(private)
record :: proc(r: ^Runner, m: Migration, duration_ms: i64, dirty: bool, loc: runtime.Source_Code_Location) -> Error {
	_, e := pg.execute(
		&r._conn,
		"migrate.record",
		"INSERT INTO _uruquim_migrations (id, name, checksum, duration_ms, tool_version, dirty) " +
		"VALUES ($1, $2, $3, $4, $5, $6)",
		{
			pg.arg_i64(m.id),
			pg.arg_text(m.name),
			pg.arg_text(m.checksum),
			pg.arg_i64(duration_ms),
			pg.arg_text(r._version),
			pg.arg_bool(dirty),
		},
	)
	if pg.is_err(e) {
		return mig_err(.Db_Error, m.id, "could not record migration", loc)
	}
	return Error{}
}

@(private)
read_history :: proc(
	r: ^Runner,
	allocator: runtime.Allocator,
	loc: runtime.Source_Code_Location,
) -> (map[i64]History, Error) {
	rows, e := pg.query(
		&r._conn,
		"migrate.history.read",
		"SELECT id, checksum, dirty, tool_version, duration_ms, applied_at::text FROM _uruquim_migrations",
	)
	defer pg.rows_close(&rows)
	if pg.is_err(e) {
		return nil, mig_err(.Db_Error, 0, "could not read history", loc)
	}
	out := make(map[i64]History, allocator)
	for pg.rows_next(&rows) {
		id, _ := pg.row_i64(&rows, 0)
		checksum, _ := pg.row_text(&rows, 1, allocator)
		dirty, _ := pg.row_bool(&rows, 2)
		version, _ := pg.row_text(&rows, 3, allocator)
		duration, _ := pg.row_i64(&rows, 4)
		applied, _ := pg.row_text(&rows, 5, allocator)
		out[id] = History {
			checksum     = checksum,
			dirty        = dirty,
			tool_version = version,
			duration_ms  = duration,
			applied_at   = applied,
		}
	}
	return out, Error{}
}

@(private)
lock :: proc(r: ^Runner, loc: runtime.Source_Code_Location) -> (bool, Error) {
	rows, e := pg.query_one(&r._conn, "migrate.lock", "SELECT pg_try_advisory_lock($1)", {pg.arg_i64(LOCK_KEY)})
	defer pg.rows_close(&rows)
	if pg.is_err(e) {
		return false, mig_err(.Db_Error, 0, "could not request advisory lock", loc)
	}
	got, de := pg.row_bool(&rows, 0)
	if pg.is_err(de) {
		return false, mig_err(.Db_Error, 0, "advisory lock did not decode", loc)
	}
	return got, Error{}
}

@(private)
unlock :: proc(r: ^Runner) {
	pg.execute(&r._conn, "migrate.unlock", "SELECT pg_advisory_unlock($1)", {pg.arg_i64(LOCK_KEY)})
}

@(private)
ms_since :: proc(start: time.Time) -> i64 {
	return i64(time.duration_milliseconds(time.since(start)))
}
