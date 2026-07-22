package postgres

import "base:runtime"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import pq "crystals:vendor/odin-postgresql"

// Exec_Opts bounds a statement that returns no rows. deadline_ms of 0 uses the
// wrapper default; it is never unbounded. deadline_ms is accepted here and
// enforced by WP77.
Exec_Opts :: struct {
	deadline_ms: int,
}

// Query_Opts bounds a statement that returns rows. Every field has a hard
// default so a single query can never accumulate an unbounded result. 0 means
// "use the wrapper default", not "unlimited". Enforcement lands in WP77.
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
// result's storage; text and bytes getters copy into caller memory so they can
// outlive the cursor.
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
execute :: proc(
	c: ^Conn,
	name: string,
	sql: string,
	params: []Param = nil,
	opts := Exec_Opts{},
	loc := #caller_location,
) -> (Command, Error) {
	if c._closed {
		return Command{}, err(.Closed, name, loc)
	}
	if c._broken {
		return Command{}, err(.Connection_Lost, name, loc)
	}

	arena: virtual.Arena
	ally := scratch(&arena)
	defer virtual.arena_destroy(&arena)

	vals, lens, fmts, n := encode_params(ally, params)
	sql_c, _ := strings.clone_to_cstring(sql, ally)
	res, timed_out := exec_with_deadline(c, sql_c, n, ptr(vals), ptr_i32(lens), ptr_fmt(fmts), opts.deadline_ms)
	if res == nil {
		c._broken = true
		return Command{}, err(.Connection_Lost, name, loc)
	}
	defer pq.clear(res)

	#partial switch pq.result_status(res) {
	case .Command_OK, .Tuples_OK:
		affected, _ := strconv.parse_i64(string(pq.cmd_tuples(res)))
		return Command{rows_affected = affected}, Error{}
	case:
		e := result_error(c, res, name, loc)
		adjust_timeout(c, &e, timed_out)
		return Command{}, e
	}
}

// exec_script runs a trusted multi-statement SQL script with no parameters,
// using the simple query protocol. It exists for migrations and setup scripts,
// where a single file legitimately contains several DDL statements; it takes no
// bound values and must never receive user input, since the simple protocol has
// no parameter separation. The statements run in the connection's current
// transaction state (inside an open transaction if one was begun).
exec_script :: proc(c: ^Conn, name: string, sql: string, loc := #caller_location) -> (Command, Error) {
	if c._closed {
		return Command{}, err(.Closed, name, loc)
	}
	if c._broken {
		return Command{}, err(.Connection_Lost, name, loc)
	}

	arena: virtual.Arena
	ally := scratch(&arena)
	defer virtual.arena_destroy(&arena)

	sql_c, _ := strings.clone_to_cstring(sql, ally)
	res := pq.exec(pq.Conn(c._pg), sql_c)
	if res == nil {
		c._broken = true
		return Command{}, err(.Connection_Lost, name, loc)
	}
	defer pq.clear(res)

	#partial switch pq.result_status(res) {
	case .Command_OK, .Tuples_OK, .Empty_Query:
		return Command{}, Error{}
	case:
		return Command{}, result_error(c, res, name, loc)
	}
}

// query runs a statement and returns a cursor. The caller closes the returned
// Rows exactly once, even on error paths.
query :: proc(
	c: ^Conn,
	name: string,
	sql: string,
	params: []Param = nil,
	opts := Query_Opts{},
	loc := #caller_location,
) -> (Rows, Error) {
	if c._closed {
		return Rows{_closed = true}, err(.Closed, name, loc)
	}
	if c._broken {
		return Rows{_closed = true}, err(.Connection_Lost, name, loc)
	}

	arena: virtual.Arena
	ally := scratch(&arena)
	defer virtual.arena_destroy(&arena)

	vals, lens, fmts, n := encode_params(ally, params)
	sql_c, _ := strings.clone_to_cstring(sql, ally)
	res, timed_out := exec_with_deadline(c, sql_c, n, ptr(vals), ptr_i32(lens), ptr_fmt(fmts), opts.deadline_ms)
	if res == nil {
		c._broken = true
		return Rows{_closed = true}, err(.Connection_Lost, name, loc)
	}

	#partial switch pq.result_status(res) {
	case .Tuples_OK, .Command_OK:
		if be := enforce_bounds(res, opts, name, loc); is_err(be) {
			pq.clear(res)
			return Rows{_closed = true}, be
		}
		return Rows{
				_res = rawptr(res),
				_conn = c,
				_row = -1,
				_nrows = int(pq.n_tuples(res)),
				_nfields = int(pq.n_fields(res)),
			},
			Error{}
	case:
		e := result_error(c, res, name, loc)
		adjust_timeout(c, &e, timed_out)
		pq.clear(res)
		return Rows{_closed = true}, e
	}
}

// enforce_bounds refuses a result that exceeds any configured hard limit before
// the caller can decode it, so an oversized value is a typed Result_Too_Large
// rather than an unbounded application allocation. libpq has already buffered the
// server's bytes; the bound caps what the wrapper will expose and copy.
@(private)
enforce_bounds :: proc(
	res: pq.Result,
	opts: Query_Opts,
	name: string,
	loc: runtime.Source_Code_Location,
) -> Error {
	nrows := int(pq.n_tuples(res))
	ncols := int(pq.n_fields(res))
	if opts.max_rows > 0 && nrows > opts.max_rows {
		return err(.Result_Too_Large, name, loc)
	}
	if opts.max_field_bytes <= 0 && opts.max_total_bytes <= 0 {
		return Error{}
	}
	total := 0
	for row in 0 ..< nrows {
		for col in 0 ..< ncols {
			l := int(pq.get_length(res, i32(row), i32(col)))
			if opts.max_field_bytes > 0 && l > opts.max_field_bytes {
				return err(.Result_Too_Large, name, loc)
			}
			total += l
			if opts.max_total_bytes > 0 && total > opts.max_total_bytes {
				return err(.Result_Too_Large, name, loc)
			}
		}
	}
	return Error{}
}

// adjust_timeout reinterprets a failure that coincided with a dispatched
// cancellation. A server-confirmed 57014 is a Timeout; any other outcome after a
// dispatched cancel leaves the connection uncertain and quarantined.
@(private)
adjust_timeout :: proc(c: ^Conn, e: ^Error, timed_out: bool) {
	if !timed_out {
		return
	}
	if err_sqlstate(e) == "57014" {
		e.kind = .Timeout
	} else {
		c._broken = true
		e.kind = .Connection_Lost
	}
}

// query_one runs a statement that must return exactly one row. Zero rows is
// Row_Not_Found; more than one is Too_Many_Rows. The single row is left current
// so the caller can decode it before closing.
query_one :: proc(
	c: ^Conn,
	name: string,
	sql: string,
	params: []Param = nil,
	opts := Query_Opts{},
	loc := #caller_location,
) -> (Rows, Error) {
	r, e := query(c, name, sql, params, opts, loc)
	if is_err(e) {
		return r, e
	}
	if r._nrows == 0 {
		rows_close(&r)
		return Rows{_closed = true}, err(.Row_Not_Found, name, loc)
	}
	if r._nrows > 1 {
		rows_close(&r)
		return Rows{_closed = true}, err(.Too_Many_Rows, name, loc)
	}
	r._row = 0
	return r, Error{}
}

// rows_next advances to the next row. It returns false at the end of the result.
rows_next :: proc(r: ^Rows) -> bool {
	if r._closed || r._res == nil {
		return false
	}
	r._row += 1
	return r._row < r._nrows
}

// rows_err returns any error that ended iteration. In the synchronous wrapper
// query failures surface up front, so a live cursor has no deferred error.
rows_err :: proc(r: ^Rows, loc := #caller_location) -> Error {
	return Error{}
}

// rows_close releases the result handle exactly once. Safe on a zero or already
// closed Rows.
rows_close :: proc(r: ^Rows) {
	if !r._closed && r._res != nil {
		pq.clear(pq.Result(r._res))
		r._res = nil
	}
	r._closed = true
}

// column resolves a column name to its index. An unknown name is Decode_Shape,
// never a silent -1.
column :: proc(r: ^Rows, name: string, loc := #caller_location) -> (int, Error) {
	if r._res == nil {
		return 0, err(.Decode_Shape, "postgres.column", loc)
	}
	name_c := strings.clone_to_cstring(name, context.temp_allocator)
	idx := pq.f_number(pq.Result(r._res), name_c)
	if idx < 0 {
		return 0, err(.Decode_Shape, "postgres.column", loc)
	}
	return int(idx), Error{}
}

// row_is_null reports whether the current row's column is SQL NULL. A column
// index out of range, or no current row, is Decode_Shape.
row_is_null :: proc(r: ^Rows, col: int, loc := #caller_location) -> (bool, Error) {
	if !cur_ok(r) || !col_ok(r, col) {
		return false, err(.Decode_Shape, "postgres.row_is_null", loc)
	}
	return bool(pq.get_is_null(pq.Result(r._res), i32(r._row), i32(col))), Error{}
}

@(private)
cur_ok :: proc "contextless" (r: ^Rows) -> bool {
	return r._res != nil && !r._closed && r._row >= 0 && r._row < r._nrows
}

@(private)
col_ok :: proc "contextless" (r: ^Rows, col: int) -> bool {
	return col >= 0 && col < r._nfields
}

// col_value validates the cursor position and returns the column OID, its text
// representation and whether it is NULL. Shape problems fail closed.
@(private)
col_value :: proc(
	r: ^Rows,
	col: int,
	name: string,
	loc: runtime.Source_Code_Location,
) -> (oid: u32, text: string, is_null: bool, e: Error) {
	if !cur_ok(r) || !col_ok(r, col) {
		return 0, "", false, err(.Decode_Shape, name, loc)
	}
	res := pq.Result(r._res)
	row := i32(r._row)
	c := i32(col)
	if bool(pq.get_is_null(res, row, c)) {
		return u32(pq.f_type(res, c)), "", true, Error{}
	}
	v := pq.get_value(res, row, c)
	n := int(pq.get_length(res, row, c))
	return u32(pq.f_type(res, c)), string(v[:n]), false, Error{}
}

// --- non-optional getters: NULL is Decode_Null, wrong type Decode_Type_Mismatch,
//     out-of-range Decode_Overflow. None leaves a zero value behind on failure. ---

row_i64 :: proc(r: ^Rows, col: int, loc := #caller_location) -> (i64, Error) {
	oid, text, is_null, e := col_value(r, col, "postgres.row_i64", loc)
	if is_err(e) {
		return 0, e
	}
	if is_null {
		return 0, err(.Decode_Null, "postgres.row_i64", loc)
	}
	if !is_int_oid(oid) {
		return 0, err(.Decode_Type_Mismatch, "postgres.row_i64", loc)
	}
	v, ok := strconv.parse_i64(text)
	if !ok {
		return 0, err(.Decode_Type_Mismatch, "postgres.row_i64", loc)
	}
	return v, Error{}
}

row_i32 :: proc(r: ^Rows, col: int, loc := #caller_location) -> (i32, Error) {
	oid, text, is_null, e := col_value(r, col, "postgres.row_i32", loc)
	if is_err(e) {
		return 0, e
	}
	if is_null {
		return 0, err(.Decode_Null, "postgres.row_i32", loc)
	}
	if !is_int_oid(oid) {
		return 0, err(.Decode_Type_Mismatch, "postgres.row_i32", loc)
	}
	v, ok := strconv.parse_i64(text)
	if !ok {
		return 0, err(.Decode_Type_Mismatch, "postgres.row_i32", loc)
	}
	if v < i64(min(i32)) || v > i64(max(i32)) {
		return 0, err(.Decode_Overflow, "postgres.row_i32", loc)
	}
	return i32(v), Error{}
}

row_f64 :: proc(r: ^Rows, col: int, loc := #caller_location) -> (f64, Error) {
	oid, text, is_null, e := col_value(r, col, "postgres.row_f64", loc)
	if is_err(e) {
		return 0, e
	}
	if is_null {
		return 0, err(.Decode_Null, "postgres.row_f64", loc)
	}
	if !is_float_oid(oid) && !is_int_oid(oid) && oid != OID_NUMERIC {
		return 0, err(.Decode_Type_Mismatch, "postgres.row_f64", loc)
	}
	v, ok := strconv.parse_f64(text)
	if !ok {
		return 0, err(.Decode_Type_Mismatch, "postgres.row_f64", loc)
	}
	return v, Error{}
}

row_bool :: proc(r: ^Rows, col: int, loc := #caller_location) -> (bool, Error) {
	oid, text, is_null, e := col_value(r, col, "postgres.row_bool", loc)
	if is_err(e) {
		return false, e
	}
	if is_null {
		return false, err(.Decode_Null, "postgres.row_bool", loc)
	}
	if oid != OID_BOOL {
		return false, err(.Decode_Type_Mismatch, "postgres.row_bool", loc)
	}
	switch text {
	case "t":
		return true, Error{}
	case "f":
		return false, Error{}
	}
	return false, err(.Decode_Type_Mismatch, "postgres.row_bool", loc)
}

// row_text copies the column into a string allocated in `allocator`. The caller
// owns and frees it.
row_text :: proc(
	r: ^Rows,
	col: int,
	allocator := context.allocator,
	loc := #caller_location,
) -> (string, Error) {
	oid, text, is_null, e := col_value(r, col, "postgres.row_text", loc)
	if is_err(e) {
		return "", e
	}
	if is_null {
		return "", err(.Decode_Null, "postgres.row_text", loc)
	}
	if !is_text_oid(oid) {
		return "", err(.Decode_Type_Mismatch, "postgres.row_text", loc)
	}
	return strings.clone(text, allocator), Error{}
}

// row_bytes copies a bytea column into a slice allocated in `allocator`.
row_bytes :: proc(
	r: ^Rows,
	col: int,
	allocator := context.allocator,
	loc := #caller_location,
) -> ([]byte, Error) {
	oid, text, is_null, e := col_value(r, col, "postgres.row_bytes", loc)
	if is_err(e) {
		return nil, e
	}
	if is_null {
		return nil, err(.Decode_Null, "postgres.row_bytes", loc)
	}
	if oid != OID_BYTEA {
		return nil, err(.Decode_Type_Mismatch, "postgres.row_bytes", loc)
	}
	out, ok := decode_bytea_hex(text, allocator)
	if !ok {
		return nil, err(.Decode_Type_Mismatch, "postgres.row_bytes", loc)
	}
	return out, Error{}
}

// --- optional getters: SQL NULL is a nil Maybe, a value is present; still
//     fail closed on type mismatch or overflow. ---

row_opt_i64 :: proc(r: ^Rows, col: int, loc := #caller_location) -> (Maybe(i64), Error) {
	is_null, e := row_is_null(r, col, loc)
	if is_err(e) {
		return nil, e
	}
	if is_null {
		return nil, Error{}
	}
	v, ve := row_i64(r, col, loc)
	if is_err(ve) {
		return nil, ve
	}
	return v, Error{}
}

row_opt_f64 :: proc(r: ^Rows, col: int, loc := #caller_location) -> (Maybe(f64), Error) {
	is_null, e := row_is_null(r, col, loc)
	if is_err(e) {
		return nil, e
	}
	if is_null {
		return nil, Error{}
	}
	v, ve := row_f64(r, col, loc)
	if is_err(ve) {
		return nil, ve
	}
	return v, Error{}
}

row_opt_bool :: proc(r: ^Rows, col: int, loc := #caller_location) -> (Maybe(bool), Error) {
	is_null, e := row_is_null(r, col, loc)
	if is_err(e) {
		return nil, e
	}
	if is_null {
		return nil, Error{}
	}
	v, ve := row_bool(r, col, loc)
	if is_err(ve) {
		return nil, ve
	}
	return v, Error{}
}

row_opt_text :: proc(
	r: ^Rows,
	col: int,
	allocator := context.allocator,
	loc := #caller_location,
) -> (Maybe(string), Error) {
	is_null, e := row_is_null(r, col, loc)
	if is_err(e) {
		return nil, e
	}
	if is_null {
		return nil, Error{}
	}
	v, ve := row_text(r, col, allocator, loc)
	if is_err(ve) {
		return nil, ve
	}
	return v, Error{}
}

// decode_bytea_hex decodes PostgreSQL's "\x…" hex bytea text representation.
@(private)
decode_bytea_hex :: proc(text: string, allocator := context.allocator) -> ([]byte, bool) {
	if len(text) < 2 || text[0] != '\\' || text[1] != 'x' {
		return nil, false
	}
	hex := text[2:]
	if len(hex) % 2 != 0 {
		return nil, false
	}
	out := make([]byte, len(hex) / 2, allocator)
	for i := 0; i < len(hex); i += 2 {
		hi, ok1 := hex_nibble(hex[i])
		lo, ok2 := hex_nibble(hex[i + 1])
		if !ok1 || !ok2 {
			delete(out, allocator)
			return nil, false
		}
		out[i / 2] = hi << 4 | lo
	}
	return out, true
}

@(private)
hex_nibble :: proc "contextless" (c: byte) -> (byte, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}
