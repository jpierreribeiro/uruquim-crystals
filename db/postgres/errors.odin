package postgres

import "base:runtime"

// Error_Kind is the typed vocabulary of PostgreSQL failures the wrapper
// promises. It is a database vocabulary: it never decides that a condition is
// HTTP 404 or 409. Application code translates at the transport boundary.
//
// The set is frozen by WP75's corpus and implemented across WP76 (execution,
// decoding, SQLSTATE mapping), WP77 (pool, timeout, cancellation) and WP78
// (transactions). `Unimplemented` exists only while the wrapper is a skeleton;
// no green test may accept it.
Error_Kind :: enum u32 {
	None = 0,

	// The wrapper surface exists but its body is not written yet. WP75 uses
	// this to keep the corpus RED-under-control. It must never survive into a
	// passing WP76+ test.
	Unimplemented,

	// Configuration rejected before any socket is opened: an impossible TLS
	// policy, a plaintext profile outside the explicit test opt-in, a missing
	// required field.
	Config_Invalid,

	// libpq reports it is not thread-safe. Startup refuses.
	Not_Thread_Safe,

	// The connection could not be established for a non-authentication reason
	// (host unreachable, refused, TLS negotiation failed).
	Connect_Failed,

	// Authentication failed, or the server offered a mechanism weaker than the
	// required SCRAM-SHA-256 profile.
	Auth_Failed,

	// The requested TLS verification could not be honored (no verify-full, no
	// channel binding where required, certificate rejected).
	Tls_Failed,

	// The connection was lost before, during or after a command. The physical
	// connection is uncertain and must be quarantined, never pooled.
	Connection_Lost,

	// The server spoke something the client could not reconcile: an unexpected
	// result shape for the requested single-command extended query.
	Protocol_Violation,

	// SQLSTATE class 23 integrity violations, split so the application does not
	// parse SQLSTATE strings itself.
	Unique_Violation,
	Foreign_Key_Violation,
	Not_Null_Violation,
	Check_Violation,

	// SQLSTATE class 40 concurrency failures a caller may choose to retry.
	Serialization_Failure,
	Deadlock,

	// A command failed with a SQLSTATE that is preserved but not further
	// classified. `sqlstate` carries the raw five characters.
	Query_Failed,

	// The local query deadline elapsed and the server confirmed cancellation
	// (SQLSTATE 57014). A dispatched cancel that the server did not confirm is
	// reported as Connection_Lost with the connection discarded, never as a
	// successful Canceled.
	Timeout,
	Canceled,

	// The bounded pool had no connection available within the acquire deadline.
	Pool_Exhausted,

	// Row decoding failures. Each is fail-closed: the wrapper never leaves a
	// zero value in place and continues.
	Decode_Null,           // SQL NULL requested into a non-optional destination
	Decode_Type_Mismatch,  // column OID/text cannot become the requested type
	Decode_Overflow,       // value does not fit the requested integer width
	Decode_Shape,          // column index out of range or result shape wrong

	// query_one found zero rows, or more than the single row it promised.
	Row_Not_Found,
	Too_Many_Rows,

	// A hard bound (rows, columns, field bytes, total bytes) was exceeded.
	Result_Too_Large,

	// The connection, pool or transaction was already closed or in a terminal
	// state incompatible with the requested operation.
	Closed,

	// Any failure the wrapper cannot place. `sqlstate` is preserved if present.
	Unknown,
}

// Error is small and returned by value alongside every fallible operation. It
// carries a stable kind, the raw SQLSTATE when the server supplied one, a
// caller-provided safe operation name and a safe metadata fragment (constraint,
// column or table name). It never carries SQL text, bound values, credentials,
// DSNs, personal data or the raw human server message.
//
// `query` borrows the caller's operation-name literal (static lifetime).
// `detail` borrows an internal per-connection scratch buffer and is valid only
// until the next operation on the connection that produced it; copy it if you
// need it longer.
Error :: struct {
	kind:     Error_Kind,
	sqlstate: [5]u8,
	query:    string,
	detail:   string,
	loc:      runtime.Source_Code_Location,
}

// is_err reports whether an operation failed.
is_err :: proc "contextless" (e: Error) -> bool {
	return e.kind != .None
}

// err_sqlstate returns the five-character SQLSTATE, or "" when the failure did
// not come from a server error report. The result borrows the Error, so the
// Error must outlive the returned string.
err_sqlstate :: proc "contextless" (e: ^Error) -> string {
	if e.sqlstate[0] == 0 {
		return ""
	}
	return string(e.sqlstate[:])
}

@(private)
err :: proc(kind: Error_Kind, query: string, loc: runtime.Source_Code_Location) -> Error {
	return Error{kind = kind, query = query, loc = loc}
}

@(private)
unimplemented_err :: proc(query: string, loc: runtime.Source_Code_Location) -> Error {
	return Error{kind = .Unimplemented, query = query, loc = loc}
}

@(private)
set_sqlstate :: proc(e: ^Error, code: string) {
	e.sqlstate = {}
	n := min(len(code), 5)
	for i in 0 ..< n {
		e.sqlstate[i] = code[i]
	}
}
