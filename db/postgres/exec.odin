package postgres

// Exec_Opts bounds a statement that returns no rows. deadline_ms of 0 uses the
// wrapper default; it is never unbounded (WP77).
Exec_Opts :: struct {
	deadline_ms: int,
}

// Query_Opts bounds a statement that returns rows. Every field has a hard
// default so a single query can never accumulate an unbounded result. 0 means
// "use the wrapper default", not "unlimited" (WP77).
Query_Opts :: struct {
	deadline_ms:     int,
	max_rows:        int,
	max_field_bytes: int,
	max_total_bytes: int,
}

// Command is the outcome of a row-less statement.
Command :: struct {
	rows_affected: i64,
}

// Rows is a forward cursor over a query result. It owns the libpq result handle
// (kept opaque) and must be closed exactly once. Column values borrow the
// result's storage and are only valid until the next rows_next or rows_close;
// text and bytes getters that must outlive the row copy into caller memory.
Rows :: struct {
	_res:     rawptr, // pq.Result
	_conn:    ^Conn,
	_row:     int,
	_nrows:   int,
	_nfields: int,
	_closed:  bool,
}

// execute runs a statement that returns no rows and reports the affected count.
// `name` is a safe operation label used only in diagnostics. `params` cross the
// wire separately from `sql`.
//
// WP75: skeleton. WP76 implements execution, binding and typed errors.
execute :: proc(
	c: ^Conn,
	name: string,
	sql: string,
	params: []Param = nil,
	opts := Exec_Opts{},
	loc := #caller_location,
) -> (Command, Error) {
	return Command{}, unimplemented_err(name, loc)
}

// query runs a statement and returns a cursor. The caller closes the returned
// Rows exactly once, even on error paths.
//
// WP75: skeleton. WP76 implements execution, binding and fail-closed decoding.
query :: proc(
	c: ^Conn,
	name: string,
	sql: string,
	params: []Param = nil,
	opts := Query_Opts{},
	loc := #caller_location,
) -> (Rows, Error) {
	return Rows{}, unimplemented_err(name, loc)
}

// query_one runs a statement that must return exactly one row. Zero rows is
// Row_Not_Found; more than one is Too_Many_Rows. The single row is left current
// so the caller can decode it before closing.
//
// WP75: skeleton. WP76 implements the body.
query_one :: proc(
	c: ^Conn,
	name: string,
	sql: string,
	params: []Param = nil,
	opts := Query_Opts{},
	loc := #caller_location,
) -> (Rows, Error) {
	return Rows{}, unimplemented_err(name, loc)
}

// rows_next advances to the next row. It returns false at the end of the result
// or after an error; check rows_err to distinguish exhaustion from failure.
//
// WP75: skeleton. WP76 implements the body.
rows_next :: proc(r: ^Rows) -> bool {
	return false
}

// rows_err returns any error that ended iteration.
rows_err :: proc(r: ^Rows, loc := #caller_location) -> Error {
	return unimplemented_err("postgres.rows_next", loc)
}

// rows_close releases the result handle exactly once. Safe on a zero or already
// closed Rows.
//
// WP75: skeleton. WP76 implements the body.
rows_close :: proc(r: ^Rows) {
	// no-op until WP76
}

// column resolves a column name to its index. An unknown name is Decode_Shape,
// never a silent -1.
//
// WP75: skeleton. WP76 implements the body.
column :: proc(r: ^Rows, name: string, loc := #caller_location) -> (int, Error) {
	return 0, unimplemented_err("postgres.column", loc)
}

// row_is_null reports whether the current row's column is SQL NULL. A column
// index out of range is Decode_Shape.
//
// WP75: skeleton. WP76 implements the body.
row_is_null :: proc(r: ^Rows, col: int, loc := #caller_location) -> (bool, Error) {
	return false, unimplemented_err("postgres.row_is_null", loc)
}

// Non-optional getters. A SQL NULL is Decode_Null, a wrong column type is
// Decode_Type_Mismatch, a value too large for the width is Decode_Overflow.
// None of them leaves a zero value behind on failure.
//
// WP75: skeletons. WP76 implements fail-closed decoding.

row_i64 :: proc(r: ^Rows, col: int, loc := #caller_location) -> (i64, Error) {
	return 0, unimplemented_err("postgres.row_i64", loc)
}

row_i32 :: proc(r: ^Rows, col: int, loc := #caller_location) -> (i32, Error) {
	return 0, unimplemented_err("postgres.row_i32", loc)
}

row_f64 :: proc(r: ^Rows, col: int, loc := #caller_location) -> (f64, Error) {
	return 0, unimplemented_err("postgres.row_f64", loc)
}

row_bool :: proc(r: ^Rows, col: int, loc := #caller_location) -> (bool, Error) {
	return false, unimplemented_err("postgres.row_bool", loc)
}

// row_text copies the column into a string allocated in `allocator`. The caller
// owns and frees it.
row_text :: proc(
	r: ^Rows,
	col: int,
	allocator := context.allocator,
	loc := #caller_location,
) -> (string, Error) {
	return "", unimplemented_err("postgres.row_text", loc)
}

// row_bytes copies a bytea column into a slice allocated in `allocator`.
row_bytes :: proc(
	r: ^Rows,
	col: int,
	allocator := context.allocator,
	loc := #caller_location,
) -> ([]byte, Error) {
	return nil, unimplemented_err("postgres.row_bytes", loc)
}

// Optional getters map SQL NULL to a nil Maybe and a value to a present one.
// They still fail closed on type mismatch or overflow.
//
// WP75: skeletons. WP76 implements the bodies.

row_opt_i64 :: proc(r: ^Rows, col: int, loc := #caller_location) -> (Maybe(i64), Error) {
	return nil, unimplemented_err("postgres.row_opt_i64", loc)
}

row_opt_f64 :: proc(r: ^Rows, col: int, loc := #caller_location) -> (Maybe(f64), Error) {
	return nil, unimplemented_err("postgres.row_opt_f64", loc)
}

row_opt_bool :: proc(r: ^Rows, col: int, loc := #caller_location) -> (Maybe(bool), Error) {
	return nil, unimplemented_err("postgres.row_opt_bool", loc)
}

row_opt_text :: proc(
	r: ^Rows,
	col: int,
	allocator := context.allocator,
	loc := #caller_location,
) -> (Maybe(string), Error) {
	return nil, unimplemented_err("postgres.row_opt_text", loc)
}
