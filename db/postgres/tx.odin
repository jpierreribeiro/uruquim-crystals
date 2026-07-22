package postgres

import "base:runtime"
import "core:strings"
import pq "crystals:vendor/odin-postgresql"

// Isolation selects the transaction isolation level. Default leaves the server
// default (READ COMMITTED) untouched.
Isolation :: enum u8 {
	Default = 0,
	Read_Committed,
	Repeatable_Read,
	Serializable,
}

// Tx_Options configures one transaction. read_only rejects writes at the server;
// deferrable is honored only for a serializable read-only transaction.
Tx_Options :: struct {
	isolation:  Isolation,
	read_only:  bool,
	deferrable: bool,
}

// Tx_State is the transaction lifecycle. A transaction holds exactly one borrowed
// connection until it reaches a terminal state (Committed or Rolled_Back); Failed
// marks a transaction the server has aborted, which can only be rolled back.
Tx_State :: enum u8 {
	Open = 0,
	Failed,
	Committed,
	Rolled_Back,
}

// Tx is an explicit transaction bound to one connection borrowed from a pool. It
// is not thread-safe: one transaction has one calling thread. The connection is
// not returned to the pool until the transaction reaches a terminal state, so a
// half-finished transaction can never leak back into the available set.
Tx :: struct {
	_pool:  ^Pool,
	_conn:  Conn,
	_state: Tx_State,
	_name:  string,
}

// begin borrows a connection from pool and opens a transaction on it. On any
// failure the connection is returned to the pool and a typed error is returned;
// no partial transaction is left holding a connection.
begin :: proc(pool: ^Pool, opts := Tx_Options{}, name := "tx", loc := #caller_location) -> (Tx, Error) {
	c, ae := acquire(pool, loc)
	if is_err(ae) {
		return Tx{}, ae
	}

	sql := begin_sql(opts)
	_, be := execute(&c, name, sql, nil, Exec_Opts{}, loc)
	if is_err(be) {
		// The BEGIN never took effect; the connection is still healthy unless
		// the failure itself broke it. release quarantines a broken one.
		release(pool, &c)
		return Tx{}, be
	}
	return Tx{_pool = pool, _conn = c, _state = .Open, _name = name}, Error{}
}

// tx_execute runs a row-less statement inside the transaction. A server error
// leaves the transaction Failed; further work is refused until rollback.
tx_execute :: proc(
	tx: ^Tx,
	name: string,
	sql: string,
	params: []Param = nil,
	opts := Exec_Opts{},
	loc := #caller_location,
) -> (Command, Error) {
	if e := tx_guard(tx, name, loc); is_err(e) {
		return Command{}, e
	}
	cmd, err := execute(&tx._conn, name, sql, params, opts, loc)
	tx_observe(tx)
	return cmd, err
}

// tx_query runs a statement returning rows inside the transaction.
tx_query :: proc(
	tx: ^Tx,
	name: string,
	sql: string,
	params: []Param = nil,
	opts := Query_Opts{},
	loc := #caller_location,
) -> (Rows, Error) {
	if e := tx_guard(tx, name, loc); is_err(e) {
		return Rows{_closed = true}, e
	}
	r, err := query(&tx._conn, name, sql, params, opts, loc)
	tx_observe(tx)
	return r, err
}

// tx_query_one runs a statement that must return exactly one row.
tx_query_one :: proc(
	tx: ^Tx,
	name: string,
	sql: string,
	params: []Param = nil,
	opts := Query_Opts{},
	loc := #caller_location,
) -> (Rows, Error) {
	if e := tx_guard(tx, name, loc); is_err(e) {
		return Rows{_closed = true}, e
	}
	r, err := query_one(&tx._conn, name, sql, params, opts, loc)
	tx_observe(tx)
	return r, err
}

// commit ends the transaction. Committing an already-committed transaction is an
// idempotent success. A Failed transaction cannot commit: it is rolled back and
// the failure surfaces. On success or terminal failure the connection returns to
// the pool exactly once.
commit :: proc(tx: ^Tx, loc := #caller_location) -> Error {
	switch tx._state {
	case .Committed:
		return Error{}
	case .Rolled_Back:
		return err(.Closed, tx._name, loc)
	case .Failed:
		_ = rollback(tx, loc)
		return err(.Query_Failed, tx._name, loc)
	case .Open:
	}

	if tx._conn._broken {
		tx._state = .Rolled_Back
		release(tx._pool, &tx._conn)
		return err(.Connection_Lost, tx._name, loc)
	}

	_, e := execute(&tx._conn, tx._name, "COMMIT", nil, Exec_Opts{}, loc)
	if is_err(e) {
		// COMMIT itself failed (e.g. a serialization failure); PostgreSQL has
		// already aborted. The connection is usable unless it broke.
		tx._state = .Failed
		release(tx._pool, &tx._conn)
		return e
	}
	tx._state = .Committed
	release(tx._pool, &tx._conn)
	return Error{}
}

// rollback ends the transaction by discarding it. Rolling back an already
// rolled-back transaction is an idempotent success. A broken connection is
// effectively rolled back by its disconnection and is simply returned (and
// quarantined by the pool).
rollback :: proc(tx: ^Tx, loc := #caller_location) -> Error {
	switch tx._state {
	case .Rolled_Back:
		return Error{}
	case .Committed:
		return err(.Closed, tx._name, loc)
	case .Open, .Failed:
	}

	if tx._conn._broken {
		tx._state = .Rolled_Back
		release(tx._pool, &tx._conn)
		return Error{}
	}

	_, e := execute(&tx._conn, tx._name, "ROLLBACK", nil, Exec_Opts{}, loc)
	tx._state = .Rolled_Back
	release(tx._pool, &tx._conn)
	return e
}

// rollback_if_open rolls back a transaction that has not reached a terminal
// state. It is the canonical `defer` guard and is safe to call unconditionally.
rollback_if_open :: proc(tx: ^Tx, loc := #caller_location) {
	if tx._state == .Open || tx._state == .Failed {
		_ = rollback(tx, loc)
	}
}

@(private)
tx_guard :: proc(tx: ^Tx, name: string, loc: runtime.Source_Code_Location) -> Error {
	switch tx._state {
	case .Open:
		return Error{}
	case .Failed:
		return err(.Query_Failed, name, loc)
	case .Committed, .Rolled_Back:
		return err(.Closed, name, loc)
	}
	return Error{}
}

// tx_observe marks the transaction Failed when the server reports it aborted, so
// the next operation is refused and commit becomes a rollback.
@(private)
tx_observe :: proc(tx: ^Tx) {
	if tx._state != .Open {
		return
	}
	if tx._conn._broken {
		tx._state = .Failed
		return
	}
	if pq.transaction_status(pq.Conn(tx._conn._pg)) == .In_Error {
		tx._state = .Failed
	}
}

@(private)
begin_sql :: proc(opts: Tx_Options) -> string {
	// Fixed clause combinations; no user text is interpolated.
	iso: string
	switch opts.isolation {
	case .Serializable:
		iso = " ISOLATION LEVEL SERIALIZABLE"
	case .Repeatable_Read:
		iso = " ISOLATION LEVEL REPEATABLE READ"
	case .Read_Committed:
		iso = " ISOLATION LEVEL READ COMMITTED"
	case .Default:
		iso = ""
	}
	rw := opts.read_only ? " READ ONLY" : ""
	df := (opts.read_only && opts.deferrable) ? " DEFERRABLE" : ""
	switch {
	case iso == "" && rw == "":
		return "BEGIN"
	case:
		return strings.concatenate({"BEGIN", iso, rw, df}, context.temp_allocator)
	}
}
