package validate_http

// The thin HTTP adapter for transport-free validation. It maps a set of
// validation field errors onto the framework's Phase-6 error envelope without
// teaching the validation package anything about status codes. Domain validation
// stays in crystals:validate; only this file knows about HTTP.

import "crystals:validate"
import web "uruquim:web"

// The envelope mirrors WP68's {"error":{"code","message"}} shape and extends it
// with a fields array for the multi-field validation case. Codes and paths are
// stable and safe; no user value ever appears.
@(private)
Envelope :: struct {
	error: Body `json:"error"`,
}

@(private)
Body :: struct {
	code:    string `json:"code"`,
	message: string `json:"message"`,
	fields:  []Field `json:"fields"`,
}

@(private)
Field :: struct {
	path: string `json:"path"`,
	code: string `json:"code"`,
}

// STATUS is the response status for a validation failure: 400, matching WP68's
// invalid_field classification for a value that fails a declared rule.
STATUS :: web.Status.Bad_Request

// respond writes the validation error envelope for a non-empty set of field
// errors. The caller returns from the handler afterward.
respond :: proc(ctx: ^web.Context, errs: []validate.Field_Error) {
	fields := make([]Field, len(errs), context.temp_allocator)
	for e, i in errs {
		fields[i] = Field{path = e.path, code = e.code}
	}
	web.json(ctx, STATUS, Envelope{error = Body{code = "invalid_field", message = "Request has invalid fields", fields = fields}})
}

// respond_if_invalid writes the envelope and returns true when the validator
// holds errors, so a handler can `if respond_if_invalid(ctx, &v) { return }`.
// It returns false and writes nothing when the input is valid.
respond_if_invalid :: proc(ctx: ^web.Context, v: ^validate.Validator) -> bool {
	if !validate.has_errors(v) {
		return false
	}
	respond(ctx, validate.errors(v))
	return true
}
