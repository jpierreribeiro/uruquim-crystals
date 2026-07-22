package main

// The deployable notes server. Migrations are NOT run here — they are a separate
// deploy step (`migrate up`) that must complete before this process starts. This
// program only opens the pool, mounts the routes and serves.
//
// Environment: NOTES_PORT, NOTES_DB_HOST, NOTES_DB_PORT, NOTES_DB_USER,
// NOTES_DB_PASSWORD, NOTES_DB_NAME, NOTES_DB_SSLMODE
// (verify-full|verify-ca|require|disable), NOTES_ALLOW_PLAINTEXT=1.

import "core:fmt"
import "core:os"
import "core:strconv"
import notes "crystals:examples/notes"
import pg "crystals:db/postgres"
import health "crystals:web/health"
import web "uruquim:web"

env :: proc(key: string, def := "") -> string {
	v := os.get_env(key, context.temp_allocator)
	return v if v != "" else def
}

main :: proc() {
	db_port, _ := strconv.parse_int(env("NOTES_DB_PORT", "5432"), 10)
	ssl: pg.Ssl_Mode = .Verify_Full
	switch env("NOTES_DB_SSLMODE", "verify-full") {
	case "verify-ca":
		ssl = .Verify_Ca
	case "require":
		ssl = .Require
	case "disable":
		ssl = .Disable
	}

	cfg := notes.Config {
		database = pg.Config {
			host                 = env("NOTES_DB_HOST", "127.0.0.1"),
			port                 = u16(db_port),
			user                 = env("NOTES_DB_USER"),
			password             = env("NOTES_DB_PASSWORD"),
			database             = env("NOTES_DB_NAME"),
			ssl_mode             = ssl,
			allow_plaintext      = env("NOTES_ALLOW_PLAINTEXT") == "1",
			statement_timeout_ms = 30_000,
		},
		// Pool capacity stays below the framework's handler-lane capacity so a
		// saturated pool fails fast for database work while health and shutdown
		// stay live.
		pool = pg.Pool_Config{min_conns = 1, max_conns = 8, acquire_timeout_ms = 2_000},
	}

	st, ok := notes.application_init(cfg)
	if !ok {
		fmt.eprintln("notes: could not open the database pool; check the configuration")
		os.exit(1)
	}
	defer notes.application_destroy(&st)

	app := web.app_with_state(&st)
	defer web.destroy(&app)

	liveness := health.routes()
	web.mount(&app, "/health", &liveness)
	web.destroy(&liveness)

	notes.register(&app)

	serve_port, _ := strconv.parse_int(env("NOTES_PORT", "8080"), 10)
	web.serve(&app, serve_port)
}
