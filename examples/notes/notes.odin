package notes

// A small, conventional CRUD service over PostgreSQL. It reads like a Gin
// application: explicit handlers, explicit SQL, explicit ownership. The
// interesting parts are the ones the framework and Crystals make ordinary —
// strict JSON, structured validation errors, SQL NULL, three-state PATCH, a
// unique-constraint conflict, a bounded pool and keyset pagination.

import "base:runtime"
import "core:encoding/json"
import "core:mem/virtual"
import pg "crystals:db/postgres"
import "crystals:validate"
import vh "crystals:web/validate"
import web "uruquim:web"

Note :: struct {
	id:         i64            `json:"id"`,
	slug:       string         `json:"slug"`,
	title:      string         `json:"title"`,
	body:       Maybe(string)  `json:"body"`, // JSON null when the column is NULL
	created_at: string         `json:"created_at"`,
}

Create_Note :: struct {
	slug:  string        `json:"slug"`,
	title: string        `json:"title"`,
	body:  Maybe(string) `json:"body"`,
}

List_Response :: struct {
	notes:      []Note `json:"notes"`,
	next_after: i64    `json:"next_after"`,
}

NOTE_COLUMNS :: "id, slug, title, body, created_at::text"

// register mounts the notes routes directly on the application's router. The app
// owns these routes, so it registers them itself rather than mounting a detached
// Crystal router.
register :: proc(app: ^web.App) {
	web.post(app, "/notes", create_note)
	web.get(app, "/notes", list_notes)
	web.get(app, "/notes/:id", get_note)
	web.patch(app, "/notes/:id", patch_note)
	web.delete(app, "/notes/:id", delete_note)
}

@(private)
create_note :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	input: Create_Note
	if !web.body(ctx, &input) {
		return // web.body already committed the strict-decode error
	}

	v := validate.validator()
	defer validate.destroy(&v)
	validate.not_empty(&v, "slug", input.slug)
	validate.string_length(&v, "slug", input.slug, min = 1, max = 64)
	validate.not_empty(&v, "title", input.title)
	validate.string_length(&v, "title", input.title, min = 1, max = 200)
	if vh.respond_if_invalid(ctx, &v) {
		return
	}

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	body_param := pg.arg_null()
	if b, has := input.body.?; has {
		body_param = pg.arg_text(b)
	}
	r, qe := pg.query_one(
		&c,
		"notes.insert",
		"INSERT INTO notes (slug, title, body) VALUES ($1, $2, $3) RETURNING " + NOTE_COLUMNS,
		{pg.arg_text(input.slug), pg.arg_text(input.title), body_param},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		if qe.kind == .Unique_Violation {
			respond_conflict(ctx)
			return
		}
		respond_db_error(ctx, qe)
		return
	}
	web.created(ctx, scan_note(&r, ally))
}

@(private)
get_note :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)
	id, ok := web.path_int(ctx, "id")
	if !ok {
		web.bad_request(ctx, "id must be an integer")
		return
	}

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	r, qe := pg.query_one(
		&c,
		"notes.by_id",
		"SELECT " + NOTE_COLUMNS + " FROM notes WHERE id = $1",
		{pg.arg_i64(i64(id))},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		if qe.kind == .Row_Not_Found {
			web.not_found(ctx, "note")
			return
		}
		respond_db_error(ctx, qe)
		return
	}
	web.ok(ctx, scan_note(&r, ally))
}

@(private)
list_notes :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)
	limit, _ := web.query_int_or(ctx, "limit", 20)
	if limit < 1 {
		limit = 1
	}
	if limit > 100 {
		limit = 100
	}
	after, _ := web.query_int_or(ctx, "after", 0)

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	// Keyset pagination with a stable total order on the primary key.
	rows, qe := pg.query(
		&c,
		"notes.list",
		"SELECT " + NOTE_COLUMNS + " FROM notes WHERE id > $1 ORDER BY id ASC LIMIT $2",
		{pg.arg_i64(i64(after)), pg.arg_i64(i64(limit))},
		pg.Query_Opts{max_rows = 100},
	)
	defer pg.rows_close(&rows)
	if pg.is_err(qe) {
		respond_db_error(ctx, qe)
		return
	}

	list := make([dynamic]Note, ally)
	next_after := i64(after)
	for pg.rows_next(&rows) {
		n := scan_note(&rows, ally)
		next_after = n.id
		append(&list, n)
	}
	web.ok(ctx, List_Response{notes = list[:], next_after = next_after})
}

@(private)
patch_note :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)
	id, ok := web.path_int(ctx, "id")
	if !ok {
		web.bad_request(ctx, "id must be an integer")
		return
	}

	title_p, body_p, perr := parse_patch(ctx.request.body)
	if perr {
		web.bad_request(ctx, "request body must be a JSON object with only title and body")
		return
	}

	v := validate.validator()
	defer validate.destroy(&v)
	validate.deny_null(&v, "title", title_p.state) // title is not nullable
	if title_p.state == .Set {
		validate.not_empty(&v, "title", title_p.value)
		validate.string_length(&v, "title", title_p.value, min = 1, max = 200)
	}
	if vh.respond_if_invalid(ctx, &v) {
		return
	}

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	// A single explicit statement expresses all three PATCH intents per column:
	// leave (present=false), clear (present=true, value NULL) or replace.
	title_present := title_p.state == .Set
	body_present := body_p.state != .Absent

	title_value := pg.arg_null()
	if title_present {
		title_value = pg.arg_text(title_p.value)
	}
	body_value := pg.arg_null()
	if body_p.state == .Set {
		body_value = pg.arg_text(body_p.value)
	}

	r, qe := pg.query_one(
		&c,
		"notes.patch",
		"UPDATE notes SET " +
		"title = CASE WHEN $2 THEN $1 ELSE title END, " +
		"body = CASE WHEN $4 THEN $3 ELSE body END " +
		"WHERE id = $5 RETURNING " + NOTE_COLUMNS,
		{title_value, pg.arg_bool(title_present), body_value, pg.arg_bool(body_present), pg.arg_i64(i64(id))},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		if qe.kind == .Row_Not_Found {
			web.not_found(ctx, "note")
			return
		}
		respond_db_error(ctx, qe)
		return
	}
	web.ok(ctx, scan_note(&r, ally))
}

@(private)
delete_note :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)
	id, ok := web.path_int(ctx, "id")
	if !ok {
		web.bad_request(ctx, "id must be an integer")
		return
	}

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	cmd, qe := pg.execute(&c, "notes.delete", "DELETE FROM notes WHERE id = $1", {pg.arg_i64(i64(id))})
	if pg.is_err(qe) {
		respond_db_error(ctx, qe)
		return
	}
	if cmd.rows_affected == 0 {
		web.not_found(ctx, "note")
		return
	}
	web.no_content(ctx)
}

// --- helpers ---

@(private)
scan_note :: proc(r: ^pg.Rows, allocator: runtime.Allocator) -> Note {
	id, _ := pg.row_i64(r, 0)
	slug, _ := pg.row_text(r, 1, allocator)
	title, _ := pg.row_text(r, 2, allocator)
	body, _ := pg.row_opt_text(r, 3, allocator)
	created, _ := pg.row_text(r, 4, allocator)
	return Note{id = id, slug = slug, title = title, body = body, created_at = created}
}

@(private)
handler_arena :: proc(arena: ^virtual.Arena) -> runtime.Allocator {
	_ = virtual.arena_init_growing(arena)
	return virtual.arena_allocator(arena)
}

// parse_patch reads the three-state intent for title and body from the raw JSON
// body. A key that is absent, JSON null, or a string maps to Absent, Null or Set.
// Any other key, or a non-string/non-null value, or a non-object body, is an
// error — the PATCH surface is strict.
@(private)
parse_patch :: proc(body: []u8) -> (title: validate.Patch(string), note_body: validate.Patch(string), err: bool) {
	value, perr := json.parse(body, allocator = context.temp_allocator)
	if perr != .None {
		return {}, {}, true
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return {}, {}, true
	}
	for key, v in obj {
		switch key {
		case "title":
			title, err = read_string_patch(v)
		case "body":
			note_body, err = read_string_patch(v)
		case:
			return {}, {}, true // unknown field
		}
		if err {
			return {}, {}, true
		}
	}
	return title, note_body, false
}

@(private)
read_string_patch :: proc(v: json.Value) -> (validate.Patch(string), bool) {
	#partial switch t in v {
	case json.Null:
		return validate.patch_null(string), false
	case json.String:
		return validate.patch_set(string(t)), false
	}
	return {}, true // a title/body that is neither null nor a string is invalid
}

@(private)
respond_conflict :: proc(ctx: ^web.Context) {
	web.json(ctx, web.Status(409), Message_Envelope{error = Message{code = "conflict", message = "A note with that slug already exists"}})
}

@(private)
respond_db_error :: proc(ctx: ^web.Context, e: pg.Error) {
	#partial switch e.kind {
	case .Pool_Exhausted, .Timeout, .Canceled, .Connection_Lost:
		web.json(
			ctx,
			web.Status(503),
			Message_Envelope{error = Message{code = "unavailable", message = "The service is temporarily unavailable"}},
		)
	case:
		web.internal_error(ctx)
	}
}

@(private)
Message_Envelope :: struct {
	error: Message `json:"error"`,
}

@(private)
Message :: struct {
	code:    string `json:"code"`,
	message: string `json:"message"`,
}
