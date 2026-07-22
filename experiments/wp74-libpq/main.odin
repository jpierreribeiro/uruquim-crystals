package main

import "core:fmt"
import "core:os"
import "core:strings"
import pq "crystals:vendor/odin-postgresql"

main :: proc() {
	if pq.is_thread_safe() != 1 {
		fmt.eprintln("wp74: libpq reports a non-thread-safe build")
		os.exit(2)
	}

	dsn := os.get_env("URUQUIM_TEST_DATABASE_URL", context.temp_allocator)
	if dsn == "" {
		fmt.eprintln("wp74: URUQUIM_TEST_DATABASE_URL is required")
		os.exit(3)
	}

	dsn_c := strings.clone_to_cstring(dsn)
	defer delete_cstring(dsn_c)
	conn := pq.connectdb(dsn_c)
	if conn == nil {
		fmt.eprintln("wp74: libpq returned no connection")
		os.exit(4)
	}
	defer pq.finish(conn)
	if pq.status(conn) != .Ok {
		fmt.eprintln("wp74: connection failed")
		os.exit(5)
	}
	server_version_setting := pq.parameter_status(conn, "server_version")
	if server_version_setting == nil || string(server_version_setting) == "" {
		fmt.eprintln("wp74: server_version parameter is absent")
		os.exit(6)
	}

	// PQexecParams uses the extended protocol even with zero parameters. WP75
	// owns the separate-value mutation; this prototype proves the selected ABI.
	query := pq.exec_params(conn, "SELECT 1::int", 0, nil, nil, nil, nil, .Text)
	if query == nil {
		fmt.eprintln("wp74: extended query returned no result")
		os.exit(7)
	}
	defer pq.clear(query)
	if pq.result_status(query) != .Tuples_OK || pq.n_tuples(query) != 1 || pq.n_fields(query) != 1 {
		fmt.eprintln("wp74: extended query result shape is wrong")
		os.exit(8)
	}
	value := cstring(pq.get_value(query, 0, 0))
	if string(value) != "1" {
		fmt.eprintln("wp74: extended query value is wrong")
		os.exit(9)
	}

	fmt.printf("wp74: libpq=%d thread_safe=1 protocol=%d server=%d extended_query=ok\n",
		pq.lib_version(), pq.protocol_version(conn), pq.server_version(conn))
}
