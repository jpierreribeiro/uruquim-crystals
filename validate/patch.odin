package validate

// The three-state wire value. A PATCH request distinguishes three intents that a
// zero value cannot: a field the client did not mention (Absent, leave it), a
// field explicitly set to JSON null (Null, clear it), and a field set to a value
// (Set, replace it). A create request uses the same type: Absent means the
// required field was omitted, distinct from a value that happens to be zero.
//
// Patch(T) is justified by this three-state contract, not by ORM convenience.
Patch_State :: enum u8 {
	Absent = 0, // the field was not present on the wire
	Null,       // the field was present as JSON null
	Set,        // the field was present with a value
}

Patch :: struct($T: typeid) {
	state: Patch_State,
	value: T,
}

// patch_absent, patch_null and patch_set are the explicit constructors. Absent
// is also the zero value, so a freshly decoded struct starts with every field
// absent until the decoder marks the ones the wire carried.
patch_absent :: proc($T: typeid) -> Patch(T) {
	return Patch(T){}
}

patch_null :: proc($T: typeid) -> Patch(T) {
	return Patch(T){state = .Null}
}

patch_set :: proc(v: $T) -> Patch(T) {
	return Patch(T){state = .Set, value = v}
}

patch_is_absent :: proc(p: Patch($T)) -> bool {
	return p.state == .Absent
}

patch_is_null :: proc(p: Patch($T)) -> bool {
	return p.state == .Null
}

patch_is_set :: proc(p: Patch($T)) -> bool {
	return p.state == .Set
}

// patch_get returns the value and whether it was Set. A caller must not read the
// value unless the second result is true; Absent and Null carry no value.
patch_get :: proc(p: Patch($T)) -> (T, bool) {
	return p.value, p.state == .Set
}
