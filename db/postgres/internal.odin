package postgres

// Private plumbing shared by the connection and execution surfaces. Everything
// here touches the raw libpq binding; none of it appears in a public signature.
// The FFI handles are stored as rawptr on Conn/Rows and only ever recovered
// inside this package.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import pq "crystals:vendor/odin-postgresql"

// PostgreSQL built-in type OIDs the decoders accept, from pg_type.h. Anything
// outside these sets is a typed Decode_Type_Mismatch, never a coerced guess.
@(private) OID_BOOL :: 16
@(private) OID_BYTEA :: 17
@(private) OID_CHAR :: 18
@(private) OID_NAME :: 19
@(private) OID_INT8 :: 20
@(private) OID_INT2 :: 21
@(private) OID_INT4 :: 23
@(private) OID_TEXT :: 25
@(private) OID_FLOAT4 :: 700
@(private) OID_FLOAT8 :: 701
@(private) OID_BPCHAR :: 1042
@(private) OID_VARCHAR :: 1043
@(private) OID_NUMERIC :: 1700

@(private)
is_int_oid :: proc "contextless" (oid: u32) -> bool {
	return oid == OID_INT2 || oid == OID_INT4 || oid == OID_INT8
}

@(private)
is_float_oid :: proc "contextless" (oid: u32) -> bool {
	return oid == OID_FLOAT4 || oid == OID_FLOAT8
}

@(private)
is_text_oid :: proc "contextless" (oid: u32) -> bool {
	return oid == OID_TEXT || oid == OID_VARCHAR || oid == OID_BPCHAR ||
		oid == OID_NAME || oid == OID_CHAR
}

// map_sqlstate turns a five-character SQLSTATE into the typed vocabulary so the
// application never parses SQLSTATE strings itself.
@(private)
map_sqlstate :: proc "contextless" (code: string) -> Error_Kind {
	switch code {
	case "23505":
		return .Unique_Violation
	case "23503":
		return .Foreign_Key_Violation
	case "23502":
		return .Not_Null_Violation
	case "23514":
		return .Check_Violation
	case "40001":
		return .Serialization_Failure
	case "40P01":
		return .Deadlock
	case "57014":
		return .Canceled
	case "57P01", "57P02", "57P03":
		return .Connection_Lost
	}
	// Class 08 — connection exception.
	if len(code) >= 2 && code[0] == '0' && code[1] == '8' {
		return .Connection_Lost
	}
	return .Query_Failed
}

// result_error builds a typed Error from a failed result on connection c. It
// preserves SQLSTATE and a safe constraint/column name, never the raw human
// message, and quarantines the connection if libpq now reports it as bad.
@(private)
result_error :: proc(c: ^Conn, res: pq.Result, name: string, loc: runtime.Source_Code_Location) -> Error {
	code: string
	if f := pq.result_error_field(res, .SQL_State); f != nil {
		code = string(f)
	}
	kind := map_sqlstate(code)
	if pq.status(pq.Conn(c._pg)) == .Bad {
		c._broken = true
		kind = .Connection_Lost
	}
	e := Error{kind = kind, query = name, loc = loc}
	set_sqlstate(&e, code)
	if cn := pq.result_error_field(res, .Constraint_Name); cn != nil && string(cn) != "" {
		e.detail = detail_from(c, string(cn))
	} else if col := pq.result_error_field(res, .Column_Name); col != nil && string(col) != "" {
		e.detail = detail_from(c, string(col))
	}
	return e
}

// scratch initialises the caller-owned growing arena used for the transient
// per-call encodings (parameter text, the SQL cstring, keyword/value arrays) and
// returns its allocator. The caller destroys the arena; the allocator must bind
// to the caller's arena, not a returned copy, so the arena is passed by pointer.
// libpq copies parameters into its own send buffer before the arena dies.
@(private)
scratch :: proc(arena: ^virtual.Arena) -> runtime.Allocator {
	_ = virtual.arena_init_growing(arena)
	return virtual.arena_allocator(arena)
}

@(private)
cstr :: proc(ally: runtime.Allocator, s: string) -> [^]byte {
	c, _ := strings.clone_to_cstring(s, ally)
	return transmute([^]byte)c
}

// encode_params renders bound values into libpq's parameter arrays. Values
// always cross here separately from the SQL text; text values are NUL-terminated
// (text format), bytea is sent binary, and NULL is a nil value pointer.
@(private)
encode_params :: proc(
	ally: runtime.Allocator,
	params: []Param,
) -> (
	values: [][^]byte,
	lengths: []i32,
	formats: []pq.Format,
	n: i32,
) {
	n = i32(len(params))
	if n == 0 {
		return nil, nil, nil, 0
	}
	values = make([][^]byte, n, ally)
	lengths = make([]i32, n, ally)
	formats = make([]pq.Format, n, ally)
	for p, i in params {
		switch p.kind {
		case .Null:
			values[i] = nil
			formats[i] = .Text
		case .I64:
			values[i] = cstr(ally, fmt.aprintf("%d", p.i, allocator = ally))
			formats[i] = .Text
		case .F64:
			values[i] = cstr(ally, fmt.aprintf("%v", p.f, allocator = ally))
			formats[i] = .Text
		case .Bool:
			values[i] = cstr(ally, p.b ? "t" : "f")
			formats[i] = .Text
		case .Text:
			values[i] = cstr(ally, p.s)
			formats[i] = .Text
		case .Bytes:
			values[i] = raw_data(p.bytes)
			lengths[i] = i32(len(p.bytes))
			formats[i] = .Binary
		}
	}
	return
}

@(private)
ptr :: proc "contextless" (s: [][^]byte) -> [^][^]byte {
	return raw_data(s) if len(s) > 0 else nil
}

@(private)
ptr_i32 :: proc "contextless" (s: []i32) -> [^]i32 {
	return raw_data(s) if len(s) > 0 else nil
}

@(private)
ptr_fmt :: proc "contextless" (s: []pq.Format) -> [^]pq.Format {
	return raw_data(s) if len(s) > 0 else nil
}
