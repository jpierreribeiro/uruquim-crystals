package postgres

// Param carries one bound value. Values always cross the wire separately from
// the SQL text (via libpq's PQexecParams family); the wrapper has no
// interpolation entry point, so a Param can never become SQL structure.
//
// A Param is a plain value with no owned memory. For Text and Bytes it borrows
// the caller's slice, which must stay alive for the duration of the call.
// Encoding to libpq's on-wire text form happens inside execute/query, in a
// scratch arena freed before returning.
Param :: struct {
	kind:  Param_Kind,
	i:     i64,
	f:     f64,
	b:     bool,
	s:     string,
	bytes: []byte,
}

Param_Kind :: enum u8 {
	Null = 0,
	I64,
	F64,
	Bool,
	Text,
	Bytes,
}

// arg_null binds a SQL NULL. NULL, empty and zero remain distinct: this is the
// only way to send NULL.
arg_null :: proc "contextless" () -> Param {
	return Param{kind = .Null}
}

arg_i64 :: proc "contextless" (v: i64) -> Param {
	return Param{kind = .I64, i = v}
}

arg_i32 :: proc "contextless" (v: i32) -> Param {
	return Param{kind = .I64, i = i64(v)}
}

arg_f64 :: proc "contextless" (v: f64) -> Param {
	return Param{kind = .F64, f = v}
}

arg_bool :: proc "contextless" (v: bool) -> Param {
	return Param{kind = .Bool, b = v}
}

// arg_text binds a text value. The slice is borrowed for the duration of the
// call. An empty string is a real empty string, never NULL.
arg_text :: proc "contextless" (v: string) -> Param {
	return Param{kind = .Text, s = v}
}

// arg_bytes binds a bytea value in binary format.
arg_bytes :: proc "contextless" (v: []byte) -> Param {
	return Param{kind = .Bytes, bytes = v}
}
