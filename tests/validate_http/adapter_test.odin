package validate_http_test

import "core:strings"
import "core:testing"
import vh "crystals:web/validate"
import v "crystals:validate"
import web "uruquim:web"

@(private = "file")
create_handler :: proc(ctx: ^web.Context) {
	val := v.validator()
	defer v.destroy(&val)
	// Simulate a decoded create input with a missing name and an out-of-range age.
	v.require_present(&val, "name", .Absent)
	v.int_range(&val, "age", 200, 0, 130)
	if vh.respond_if_invalid(ctx, &val) {
		return
	}
	web.text(ctx, .OK, "ok")
}

@(private = "file")
valid_handler :: proc(ctx: ^web.Context) {
	val := v.validator()
	defer v.destroy(&val)
	v.require_present(&val, "name", .Set)
	v.string_length(&val, "name", "Ada", min = 1, max = 50)
	if vh.respond_if_invalid(ctx, &val) {
		return
	}
	web.text(ctx, .OK, "ok")
}

@(test)
invalid_input_yields_a_field_error_envelope :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/users", create_handler)

	res := web.test_request(&app, .POST, "/users")
	testing.expect_value(t, res.status, web.Status.Bad_Request)
	testing.expect(t, strings.contains(res.body, `"code":"invalid_field"`), "top code is invalid_field")
	testing.expect(t, strings.contains(res.body, `"path":"name"`), "carries the field path")
	testing.expect(t, strings.contains(res.body, `"code":"required"`), "carries the rule code")
	testing.expect(t, strings.contains(res.body, `"path":"age"`), "carries every failing field")
	testing.expect(t, strings.contains(res.body, `"code":"above_max"`), "carries the range rule code")
}

@(test)
valid_input_passes_through :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/users", valid_handler)

	res := web.test_request(&app, .POST, "/users")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "ok")
}
