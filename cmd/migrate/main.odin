package main

// The migration runner executable. It is deliberately a separate program from
// any HTTP server. Configuration comes from the environment; the single
// positional argument selects the command. It exits non-zero on every refusal or
// failure so a deploy step fails loudly.
//
//   migrate up        apply every pending migration
//   migrate dry-run   report the pending plan without applying
//   migrate status    print every migration and its state
//   migrate down      revert the most recently applied migration
//
// Environment: MIGRATE_DIR, MIGRATE_HOST, MIGRATE_PORT, MIGRATE_USER,
// MIGRATE_PASSWORD, MIGRATE_DB, MIGRATE_SSLMODE (verify-full|verify-ca|require|
// disable) and MIGRATE_ALLOW_PLAINTEXT=1 to permit the disable profile.

import "core:fmt"
import "core:os"
import "core:strconv"
import mig "crystals:db/migrate"
import pg "crystals:db/postgres"

VERSION :: "uruquim-migrate/0.1"

env :: proc(key: string, def := "") -> string {
	v := os.get_env(key, context.temp_allocator)
	return v if v != "" else def
}

config_from_env :: proc() -> pg.Config {
	port, _ := strconv.parse_int(env("MIGRATE_PORT", "5432"), 10)
	allow_plaintext := env("MIGRATE_ALLOW_PLAINTEXT") == "1"
	ssl: pg.Ssl_Mode = .Verify_Full
	switch env("MIGRATE_SSLMODE", "verify-full") {
	case "verify-ca":
		ssl = .Verify_Ca
	case "require":
		ssl = .Require
	case "disable":
		ssl = .Disable
	}
	return pg.Config {
		host            = env("MIGRATE_HOST", "127.0.0.1"),
		port            = u16(port),
		user            = env("MIGRATE_USER"),
		password        = env("MIGRATE_PASSWORD"),
		database        = env("MIGRATE_DB"),
		ssl_mode        = ssl,
		allow_plaintext = allow_plaintext,
	}
}

die :: proc(msg: string, args: ..any) -> ! {
	fmt.eprintf("migrate: ")
	fmt.eprintfln(msg, ..args)
	os.exit(1)
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: migrate <up|dry-run|status|down>")
		os.exit(2)
	}
	command := os.args[1]

	ms, le := mig.load(env("MIGRATE_DIR", "migrations"))
	if mig.is_err(le) {
		die("load failed: %v (%s)", le.kind, le.detail)
	}
	defer mig.destroy_migrations(ms)

	r, oe := mig.open(config_from_env(), VERSION)
	if mig.is_err(oe) {
		die("open failed: %v", oe.kind)
	}
	defer mig.close(&r)

	switch command {
	case "up":
		n, e := mig.up(&r, ms)
		if mig.is_err(e) {
			die("up failed at id %d: %v", e.id, e.kind)
		}
		fmt.printfln("migrate: applied %d migration(s)", n)
	case "dry-run":
		plan, e := mig.status(&r, ms)
		if mig.is_err(e) {
			die("status failed: %v", e.kind)
		}
		defer mig.destroy_plan(plan)
		pending := 0
		for it in plan {
			if it.state == .Pending {
				fmt.printfln("pending %d %s", it.id, it.name)
				pending += 1
			}
		}
		fmt.printfln("migrate: %d pending migration(s)", pending)
	case "status":
		plan, e := mig.status(&r, ms)
		if mig.is_err(e) {
			die("status failed: %v", e.kind)
		}
		defer mig.destroy_plan(plan)
		for it in plan {
			fmt.printfln("%d %s %v", it.id, it.name, it.state)
		}
	case "down":
		n, e := mig.down(&r, ms)
		if mig.is_err(e) {
			die("down failed at id %d: %v", e.id, e.kind)
		}
		fmt.printfln("migrate: reverted %d migration(s)", n)
	case:
		fmt.eprintfln("migrate: unknown command %q", command)
		os.exit(2)
	}
}
