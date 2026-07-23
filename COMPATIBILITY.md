# Compatibility

Verification is commit-level while Uruquim has no stable release tag.

| Component | Verified value |
|---|---|
| Odin release | `dev-2026-07a` |
| Odin commit | `819fdc7` |
| Uruquim commit | `cdf737a6a07c24059758529e3fca7062dec91d82` |
| Uruquim phase | Phase 6 FROZEN (data stack WP73–83; see docs/phase-6-freeze.md) |
| Platform | Linux x86-64 |
| PostgreSQL server harness | `postgres:16-alpine`, pinned by digest |
| libpq ABI | `libpq.so.5`, version 16 or newer |

“Verified” means `build/check.sh` passed with that exact Uruquim tree. A
floating branch is not a compatibility declaration.

The WP74 gate was first verified with libpq 18 and PostgreSQL 16.13. The
vendored Odin declarations are the upstream 16.9 snapshot; only APIs available
since libpq 16 may enter the data Crystal.
