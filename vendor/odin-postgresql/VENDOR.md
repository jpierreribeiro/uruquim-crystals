# laytan/odin-postgresql binding snapshot

| Field | Value |
|---|---|
| Upstream | https://github.com/laytan/odin-postgresql |
| Tag | `16.9` |
| Commit | `6f33822e1d8090a218fcf4c24863235b15a3205a` |
| Vendored | 2026-07-22 |
| License | MIT |
| Target ABI | libpq 16 or newer (`libpq.so.5` on Linux) |

Only the Odin FFI declaration and its license are vendored. libpq itself is a
system runtime dependency and retains PostgreSQL's license and security update
channel.

Two local binding fixes are marked in `pq.odin`: correct the misspelled
`PQparameterStatus` link name and expose `PQisthreadsafe`. Neither changes
libpq. Both are executable in the WP74 prototype/gate. Upstream trailing
whitespace was normalized when the snapshot entered this repository.
