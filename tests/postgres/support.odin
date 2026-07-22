package postgres_test

import pg "crystals:db/postgres"

// test_config returns the pinned local test profile. It is the only DSN these
// tests accept; the destructive integration harness in
// build/check_wp75_controls.sh refuses any other database. The password is a
// throwaway test credential owned by the disposable container, never a secret.
test_config :: proc() -> pg.Config {
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
