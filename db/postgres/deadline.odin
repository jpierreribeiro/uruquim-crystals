package postgres

import "base:intrinsics"
import "core:thread"
import "core:time"
import pq "crystals:vendor/odin-postgresql"

// A query deadline is enforced by a watchdog thread that asks the server to
// abandon the running command through a read-only PGcancel object — the one
// cross-thread use libpq explicitly permits. Dispatching the cancel is not the
// same as a successful cancellation: the calling code still inspects the result
// and only trusts an interruption confirmed by SQLSTATE 57014. An unconfirmed
// cancel leaves the connection uncertain and it is quarantined.
@(private)
Watchdog :: struct {
	cancel:      pq.Cancel,
	deadline_ms: int,
	done:        i32, // set by the calling thread when the command returns
	fired:       i32, // set by the watchdog when it dispatched a cancel
}

@(private)
watchdog_run :: proc(data: rawptr) {
	w := (^Watchdog)(data)
	elapsed := 0
	for elapsed < w.deadline_ms {
		if intrinsics.atomic_load(&w.done) != 0 {
			return
		}
		time.sleep(5 * time.Millisecond)
		elapsed += 5
	}
	if intrinsics.atomic_load(&w.done) == 0 {
		errbuf: [256]byte
		pq.cancel(w.cancel, &errbuf[0], 256)
		intrinsics.atomic_store(&w.fired, 1)
	}
}

// exec_with_deadline runs one extended-query command, optionally guarded by a
// cancellation watchdog. It returns libpq's result and whether the watchdog
// actually dispatched a cancel. deadline_ms of 0 means no client-side deadline;
// a server-side statement_timeout (Config.statement_timeout_ms) can still bound
// the command.
@(private)
exec_with_deadline :: proc(
	c: ^Conn,
	sql_c: cstring,
	n: i32,
	vals: [^][^]byte,
	lens: [^]i32,
	fmts: [^]pq.Format,
	deadline_ms: int,
) -> (res: pq.Result, timed_out: bool) {
	conn := pq.Conn(c._pg)
	if deadline_ms <= 0 {
		return pq.exec_params(conn, sql_c, n, nil, vals, lens, fmts, .Text), false
	}

	cancel := pq.get_cancel(conn)
	w := Watchdog{cancel = cancel, deadline_ms = deadline_ms}
	t := thread.create_and_start_with_data(&w, watchdog_run)
	res = pq.exec_params(conn, sql_c, n, nil, vals, lens, fmts, .Text)
	intrinsics.atomic_store(&w.done, 1)
	thread.join(t)
	thread.destroy(t)
	pq.free_cancel(cancel)
	return res, intrinsics.atomic_load(&w.fired) != 0
}
