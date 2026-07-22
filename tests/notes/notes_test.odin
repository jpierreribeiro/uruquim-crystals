package notes_test

// WP83 — the reference application is the design test. These integration tests
// drive the real handlers over the in-memory transport against the pinned
// PostgreSQL server, and demonstrate the database guarantees at the application
// boundary: CRUD, strict JSON, structured validation, SQL NULL, three-state
// PATCH, a unique conflict, keyset pagination, a bounded pool that fails fast,
// a blocked query that does not stall health, query cancellation and a clean
// shutdown.

import "base:intrinsics"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import notes "crystals:examples/notes"
import mig "crystals:db/migrate"
import pg "crystals:db/postgres"
import health "crystals:web/health"
import web "uruquim:web"

JSON_HEADER := []string{"Content-Type: application/json"}

db_config :: proc() -> pg.Config {
	return pg.Config{
		host            = "127.0.0.1",
		port            = 55434,
		user            = "uruquim",
		password        = "uruquim_test_pw",
		database        = "uruquim_crystals_test",
		ssl_mode        = .Disable,
		allow_plaintext = true,
	}
}

app_config :: proc() -> notes.Config {
	return notes.Config{database = db_config(), pool = pg.Pool_Config{min_conns = 1, max_conns = 8, acquire_timeout_ms = 2000}}
}

// reset_and_migrate drops the schema and applies the app's migrations, so each
// test starts with a fresh notes table whose IDENTITY restarts at 1.
reset_and_migrate :: proc(t: ^testing.T) {
	c, _ := pg.open(db_config())
	pg.execute(&c, "reset", "DROP TABLE IF EXISTS notes")
	pg.execute(&c, "reset", "DROP TABLE IF EXISTS _uruquim_migrations")
	pg.close(&c)

	dir, _ := filepath.join({filepath.dir(#file), "..", "..", "examples", "notes", "migrations"}, context.temp_allocator)
	ms, le := mig.load(dir)
	defer mig.destroy_migrations(ms)
	testing.expect_value(t, le.kind, mig.Error_Kind.None)
	r, oe := mig.open(db_config(), "notes-test")
	defer mig.close(&r)
	testing.expect_value(t, oe.kind, mig.Error_Kind.None)
	_, ue := mig.up(&r, ms)
	testing.expect_value(t, ue.kind, mig.Error_Kind.None)
}

serve_app :: proc(st: ^notes.App_State) -> web.App {
	app := web.app_with_state(st)
	liveness := health.routes()
	web.mount(&app, "/health", &liveness)
	web.destroy(&liveness)
	notes.register(&app)
	return app
}

@(test)
crud_roundtrip_and_sql_null :: proc(t: ^testing.T) {
	reset_and_migrate(t)
	st, ok := notes.application_init(app_config())
	testing.expect(t, ok, "init")
	defer notes.application_destroy(&st)
	app := serve_app(&st)
	defer web.destroy(&app)

	// Create with a body.
	res := web.test_request(&app, .POST, "/notes", `{"slug":"first","title":"First","body":"hello"}`, "", JSON_HEADER)
	testing.expect_value(t, res.status, web.Status.Created)
	testing.expect(t, strings.contains(res.body, `"id":1`), "returns the generated id")
	testing.expect(t, strings.contains(res.body, `"body":"hello"`), "returns the body")

	// Create without a body: SQL NULL surfaces as JSON null.
	res2 := web.test_request(&app, .POST, "/notes", `{"slug":"second","title":"Second"}`, "", JSON_HEADER)
	testing.expect_value(t, res2.status, web.Status.Created)
	testing.expect(t, strings.contains(res2.body, `"body":null`), "an omitted body is SQL NULL, JSON null")

	// Read back.
	got := web.test_request(&app, .GET, "/notes/1")
	testing.expect_value(t, got.status, web.Status.OK)
	testing.expect(t, strings.contains(got.body, `"slug":"first"`), "reads the row")

	// Missing id is 404.
	missing := web.test_request(&app, .GET, "/notes/999")
	testing.expect_value(t, missing.status, web.Status.Not_Found)
}

@(test)
strict_json_and_validation_errors :: proc(t: ^testing.T) {
	reset_and_migrate(t)
	st, _ := notes.application_init(app_config())
	defer notes.application_destroy(&st)
	app := serve_app(&st)
	defer web.destroy(&app)

	// Unknown field: the strict decoder rejects it (WP68).
	unknown := web.test_request(&app, .POST, "/notes", `{"slug":"x","title":"y","extra":1}`, "", JSON_HEADER)
	testing.expect_value(t, unknown.status, web.Status.Bad_Request)
	testing.expect(t, strings.contains(unknown.body, "unknown_field"), "unknown field rejected")

	// Empty required fields: structured validation envelope.
	invalid := web.test_request(&app, .POST, "/notes", `{"slug":"","title":""}`, "", JSON_HEADER)
	testing.expect_value(t, invalid.status, web.Status.Bad_Request)
	testing.expect(t, strings.contains(invalid.body, `"code":"invalid_field"`), "validation envelope")
	testing.expect(t, strings.contains(invalid.body, `"path":"slug"`), "names the failing field")
}

@(test)
unique_slug_conflict_is_409 :: proc(t: ^testing.T) {
	reset_and_migrate(t)
	st, _ := notes.application_init(app_config())
	defer notes.application_destroy(&st)
	app := serve_app(&st)
	defer web.destroy(&app)

	body := `{"slug":"dup","title":"One"}`
	first := web.test_request(&app, .POST, "/notes", body, "", JSON_HEADER)
	testing.expect_value(t, first.status, web.Status.Created)
	second := web.test_request(&app, .POST, "/notes", body, "", JSON_HEADER)
	testing.expect_value(t, second.status, web.Status(409))
	testing.expect(t, strings.contains(second.body, `"code":"conflict"`), "conflict envelope")
}

@(test)
three_state_patch :: proc(t: ^testing.T) {
	reset_and_migrate(t)
	st, _ := notes.application_init(app_config())
	defer notes.application_destroy(&st)
	app := serve_app(&st)
	defer web.destroy(&app)

	web.test_request(&app, .POST, "/notes", `{"slug":"p","title":"Original","body":"keep"}`, "", JSON_HEADER)

	// Set title only: body is Absent, so it is left unchanged.
	r1 := web.test_request(&app, .PATCH, "/notes/1", `{"title":"Renamed"}`, "", JSON_HEADER)
	testing.expect_value(t, r1.status, web.Status.OK)
	testing.expect(t, strings.contains(r1.body, `"title":"Renamed"`), "title replaced")
	testing.expect(t, strings.contains(r1.body, `"body":"keep"`), "absent body left unchanged")

	// Null body: cleared to SQL NULL.
	r2 := web.test_request(&app, .PATCH, "/notes/1", `{"body":null}`, "", JSON_HEADER)
	testing.expect_value(t, r2.status, web.Status.OK)
	testing.expect(t, strings.contains(r2.body, `"body":null`), "null body clears the column")

	// Set body: replaced.
	r3 := web.test_request(&app, .PATCH, "/notes/1", `{"body":"again"}`, "", JSON_HEADER)
	testing.expect(t, strings.contains(r3.body, `"body":"again"`), "body replaced")

	// Empty patch: nothing changes, title still Renamed.
	r4 := web.test_request(&app, .PATCH, "/notes/1", `{}`, "", JSON_HEADER)
	testing.expect(t, strings.contains(r4.body, `"title":"Renamed"`), "empty patch leaves fields")

	// A null title is rejected (title is not nullable).
	r5 := web.test_request(&app, .PATCH, "/notes/1", `{"title":null}`, "", JSON_HEADER)
	testing.expect_value(t, r5.status, web.Status.Bad_Request)
	testing.expect(t, strings.contains(r5.body, "null_not_allowed"), "null title rejected")
}

@(test)
keyset_pagination_is_stable :: proc(t: ^testing.T) {
	reset_and_migrate(t)
	st, _ := notes.application_init(app_config())
	defer notes.application_destroy(&st)
	app := serve_app(&st)
	defer web.destroy(&app)

	web.test_request(&app, .POST, "/notes", `{"slug":"a","title":"A"}`, "", JSON_HEADER)
	web.test_request(&app, .POST, "/notes", `{"slug":"b","title":"B"}`, "", JSON_HEADER)
	web.test_request(&app, .POST, "/notes", `{"slug":"c","title":"C"}`, "", JSON_HEADER)

	page1 := web.test_request(&app, .GET, "/notes", "", "limit=2")
	testing.expect_value(t, page1.status, web.Status.OK)
	testing.expect(t, strings.contains(page1.body, `"slug":"a"`), "first page has a")
	testing.expect(t, strings.contains(page1.body, `"slug":"b"`), "first page has b")
	testing.expect(t, !strings.contains(page1.body, `"slug":"c"`), "first page stops at the limit")
	testing.expect(t, strings.contains(page1.body, `"next_after":2`), "reports the cursor")

	page2 := web.test_request(&app, .GET, "/notes", "", "after=2&limit=2")
	testing.expect(t, strings.contains(page2.body, `"slug":"c"`), "second page continues")
	testing.expect(t, !strings.contains(page2.body, `"slug":"a"`), "no overlap")
}

@(test)
delete_then_absent :: proc(t: ^testing.T) {
	reset_and_migrate(t)
	st, _ := notes.application_init(app_config())
	defer notes.application_destroy(&st)
	app := serve_app(&st)
	defer web.destroy(&app)

	web.test_request(&app, .POST, "/notes", `{"slug":"gone","title":"Gone"}`, "", JSON_HEADER)
	del := web.test_request(&app, .DELETE, "/notes/1")
	testing.expect_value(t, del.status, web.Status.No_Content)
	again := web.test_request(&app, .DELETE, "/notes/1")
	testing.expect_value(t, again.status, web.Status.Not_Found)
}

@(test)
saturated_pool_fails_fast_as_503 :: proc(t: ^testing.T) {
	reset_and_migrate(t)
	cfg := app_config()
	cfg.pool.max_conns = 2
	cfg.pool.acquire_timeout_ms = 200
	st, _ := notes.application_init(cfg)
	defer notes.application_destroy(&st)
	app := serve_app(&st)
	defer web.destroy(&app)

	// Hold every connection, then a request cannot acquire one.
	c1, _ := pg.acquire(&st.db)
	c2, _ := pg.acquire(&st.db)
	res := web.test_request(&app, .POST, "/notes", `{"slug":"z","title":"Z"}`, "", JSON_HEADER)
	testing.expect_value(t, res.status, web.Status(503))
	testing.expect(t, strings.contains(res.body, `"code":"unavailable"`), "typed backpressure")
	pg.release(&st.db, &c1)
	pg.release(&st.db, &c2)
}

Blocked :: struct {
	pool:  ^pg.Pool,
	ready: i32,
}

blocked_query :: proc(data: rawptr) {
	b := (^Blocked)(data)
	c, _ := pg.acquire(b.pool)
	intrinsics.atomic_store(&b.ready, 1)
	pg.execute(&c, "block", "SELECT pg_sleep(2)")
	pg.release(b.pool, &c)
}

@(test)
blocked_query_does_not_stall_health :: proc(t: ^testing.T) {
	reset_and_migrate(t)
	st, _ := notes.application_init(app_config())
	defer notes.application_destroy(&st)
	app := serve_app(&st)
	defer web.destroy(&app)

	b := Blocked{pool = &st.db}
	th := thread.create_and_start_with_data(&b, blocked_query)
	for intrinsics.atomic_load(&b.ready) == 0 {
		time.sleep(time.Millisecond)
	}

	start := time.now()
	res := web.test_request(&app, .GET, "/health/live")
	elapsed := time.since(start)
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "ok")
	testing.expect(t, time.duration_milliseconds(elapsed) < 500, "health stays live while a query blocks")

	thread.join(th)
	thread.destroy(th)
}

@(test)
query_cancellation_is_bounded :: proc(t: ^testing.T) {
	reset_and_migrate(t)
	st, _ := notes.application_init(app_config())
	defer notes.application_destroy(&st)

	// The application owns the pool, so it can bound a slow query and have it
	// cancelled server-side.
	c, _ := pg.acquire(&st.db)
	defer pg.release(&st.db, &c)
	_, qe := pg.query(&c, "slow", "SELECT pg_sleep(5)", nil, pg.Query_Opts{deadline_ms = 200})
	testing.expect_value(t, qe.kind, pg.Error_Kind.Timeout)
}

@(test)
graceful_shutdown_closes_the_pool :: proc(t: ^testing.T) {
	reset_and_migrate(t)
	st, _ := notes.application_init(app_config())

	c, _ := pg.acquire(&st.db)
	pg.release(&st.db, &c)

	notes.application_destroy(&st)
	// After shutdown the pool refuses new work.
	_, ae := pg.acquire(&st.db)
	testing.expect_value(t, ae.kind, pg.Error_Kind.Closed)
}
