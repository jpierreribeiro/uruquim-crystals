package validate_test

import "core:testing"
import v "crystals:validate"

@(test)
patch_distinguishes_absent_null_and_set :: proc(t: ^testing.T) {
	absent := v.patch_absent(i64)
	null := v.patch_null(i64)
	set := v.patch_set(i64(5))

	testing.expect(t, v.patch_is_absent(absent), "absent")
	testing.expect(t, v.patch_is_null(null), "null")
	testing.expect(t, v.patch_is_set(set), "set")

	testing.expect(t, !v.patch_is_set(absent), "absent is not set")
	testing.expect(t, !v.patch_is_null(absent), "absent is not null")

	val, ok := v.patch_get(set)
	testing.expect(t, ok, "set yields a value")
	testing.expect_value(t, val, i64(5))

	_, ok2 := v.patch_get(null)
	testing.expect(t, !ok2, "null yields no value")
}

@(test)
zero_value_is_absent_by_default :: proc(t: ^testing.T) {
	// A freshly decoded struct field starts Absent, distinct from a set zero.
	field: v.Patch(i64)
	testing.expect(t, v.patch_is_absent(field), "default Patch is absent")
	set_zero := v.patch_set(i64(0))
	testing.expect(t, v.patch_is_set(set_zero), "an explicit zero is Set, not Absent")
}

@(test)
presence_rules_flag_absent_and_null :: proc(t: ^testing.T) {
	val := v.validator()
	defer v.destroy(&val)

	v.require_present(&val, "name", .Absent)
	v.require_present(&val, "email", .Set)
	v.deny_null(&val, "email", .Null)

	errs := v.errors(&val)
	testing.expect_value(t, len(errs), 2)
	testing.expect_value(t, errs[0].path, "name")
	testing.expect_value(t, errs[0].code, v.CODE_REQUIRED)
	testing.expect_value(t, errs[1].path, "email")
	testing.expect_value(t, errs[1].code, v.CODE_NULL_NOT_ALLOWED)
}

@(test)
value_rules_carry_stable_codes :: proc(t: ^testing.T) {
	val := v.validator()
	defer v.destroy(&val)

	v.string_length(&val, "name", "ab", min = 3, max = 10)
	v.string_length(&val, "bio", "way too long here", min = 0, max = 5)
	v.int_range(&val, "age", 200, 0, 130)
	v.int_range(&val, "qty", -1, 0, 100)
	v.one_of(&val, "role", "wizard", {"admin", "user"})
	v.not_empty(&val, "title", "")

	errs := v.errors(&val)
	codes := make(map[string]string)
	defer delete(codes)
	for e in errs {
		codes[e.path] = e.code
	}
	testing.expect_value(t, codes["name"], v.CODE_TOO_SHORT)
	testing.expect_value(t, codes["bio"], v.CODE_TOO_LONG)
	testing.expect_value(t, codes["age"], v.CODE_ABOVE_MAX)
	testing.expect_value(t, codes["qty"], v.CODE_BELOW_MIN)
	testing.expect_value(t, codes["role"], v.CODE_NOT_IN_SET)
	testing.expect_value(t, codes["title"], v.CODE_REQUIRED)
}

@(test)
valid_input_produces_no_errors :: proc(t: ^testing.T) {
	val := v.validator()
	defer v.destroy(&val)

	v.require_present(&val, "name", .Set)
	v.string_length(&val, "name", "Ada", min = 1, max = 50)
	v.int_range(&val, "age", 36, 0, 130)
	v.one_of(&val, "role", "admin", {"admin", "user"})

	testing.expect(t, !v.has_errors(&val), "clean input has no errors")
}

@(test)
error_set_is_bounded :: proc(t: ^testing.T) {
	val := v.validator(max = 4)
	defer v.destroy(&val)

	for i in 0 ..< 100 {
		v.add(&val, "field", v.CODE_REQUIRED)
	}
	testing.expect_value(t, len(v.errors(&val)), 4)
	testing.expect(t, v.truncated(&val), "the error set must report truncation")
}
