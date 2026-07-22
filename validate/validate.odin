package validate

import "base:runtime"
import "core:unicode/utf8"

// Transport-free value validation. It knows nothing about HTTP: it collects
// typed field errors, each carrying a stable rule code and a field path, and the
// separate web/validate adapter maps them onto the framework's error envelope.
// There are no struct tags and no reflection, so there are no unknown flags or
// contradictory annotations to fail closed on — the rules are ordinary explicit
// calls.

// Stable rule codes. They are part of the wire contract for clients, so they do
// not change casually.
CODE_REQUIRED :: "required"
CODE_NULL_NOT_ALLOWED :: "null_not_allowed"
CODE_TOO_SHORT :: "too_short"
CODE_TOO_LONG :: "too_long"
CODE_BELOW_MIN :: "below_min"
CODE_ABOVE_MAX :: "above_max"
CODE_NOT_IN_SET :: "not_in_set"
CODE_BAD_FORMAT :: "bad_format"

// Field_Error names one failing field with a stable rule code. It never contains
// the offending value, so logging an error set leaks no user data.
Field_Error :: struct {
	path: string,
	code: string,
}

DEFAULT_MAX_ERRORS :: 64

// Validator accumulates field errors up to a hard bound. Beyond the bound it
// stops recording individual errors and marks the set truncated, so a hostile or
// broken input cannot make the error set grow without limit.
Validator :: struct {
	_errors:    [dynamic]Field_Error,
	_max:       int,
	_truncated: bool,
	_allocator: runtime.Allocator,
}

// validator creates an empty validator. Paths and codes added later are cloned
// into `allocator`; destroy frees them.
validator :: proc(allocator := context.allocator, max := DEFAULT_MAX_ERRORS) -> Validator {
	v: Validator
	v._allocator = allocator
	v._max = max if max > 0 else DEFAULT_MAX_ERRORS
	v._errors = make([dynamic]Field_Error, allocator)
	return v
}

destroy :: proc(v: ^Validator) {
	for e in v._errors {
		delete(e.path, v._allocator)
	}
	delete(v._errors)
}

// add records one field error. The path is cloned; the code is expected to be a
// stable constant and is stored by reference.
add :: proc(v: ^Validator, path: string, code: string) {
	if len(v._errors) >= v._max {
		v._truncated = true
		return
	}
	append(&v._errors, Field_Error{path = clone_path(v, path), code = code})
}

has_errors :: proc(v: ^Validator) -> bool {
	return len(v._errors) > 0
}

// errors returns the accumulated field errors, borrowed from the validator.
errors :: proc(v: ^Validator) -> []Field_Error {
	return v._errors[:]
}

// truncated reports whether the error set hit its bound and stopped recording.
truncated :: proc(v: ^Validator) -> bool {
	return v._truncated
}

// --- presence rules for wire inputs (Patch three-state) ---

// require_present fails a create/patch field that was Absent.
require_present :: proc(v: ^Validator, path: string, state: Patch_State) {
	if state == .Absent {
		add(v, path, CODE_REQUIRED)
	}
}

// deny_null fails a field that was explicitly set to JSON null where null is not
// a legal value.
deny_null :: proc(v: ^Validator, path: string, state: Patch_State) {
	if state == .Null {
		add(v, path, CODE_NULL_NOT_ALLOWED)
	}
}

// --- value rules ---

// not_empty fails an empty string.
not_empty :: proc(v: ^Validator, path: string, value: string) {
	if len(value) == 0 {
		add(v, path, CODE_REQUIRED)
	}
}

// string_length checks a string's length in Unicode runes against inclusive
// bounds. A bound of -1 disables that side.
string_length :: proc(v: ^Validator, path: string, value: string, min := -1, max := -1) {
	n := utf8.rune_count_in_string(value)
	if min >= 0 && n < min {
		add(v, path, CODE_TOO_SHORT)
	}
	if max >= 0 && n > max {
		add(v, path, CODE_TOO_LONG)
	}
}

// int_range checks an integer against inclusive bounds. Use has_min/has_max to
// disable a side.
int_range :: proc(v: ^Validator, path: string, value: i64, min: i64, max: i64, has_min := true, has_max := true) {
	if has_min && value < min {
		add(v, path, CODE_BELOW_MIN)
	}
	if has_max && value > max {
		add(v, path, CODE_ABOVE_MAX)
	}
}

// one_of fails a value that is not in the allowed set.
one_of :: proc(v: ^Validator, path: string, value: string, allowed: []string) {
	for a in allowed {
		if a == value {
			return
		}
	}
	add(v, path, CODE_NOT_IN_SET)
}

@(private)
clone_path :: proc(v: ^Validator, path: string) -> string {
	if len(path) == 0 {
		return ""
	}
	buf := make([]byte, len(path), v._allocator)
	copy(buf, path)
	return string(buf)
}
