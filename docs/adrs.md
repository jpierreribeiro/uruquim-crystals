# Crystals architecture decisions

## ADR-C001 — one-way dependency

**ACCEPTED, 2026-07-22 (WP73).** Applications import core and Crystals;
Crystals may import public core packages; core never imports, discovers,
registers or initializes a Crystal. A core change requested by a Crystal is a
failed Crystal design, not an ecosystem exception.

## ADR-C002 — application-owned composition

**ACCEPTED, 2026-07-22 (WP73).** A Route Crystal returns a detached
`web.Router`. It does not receive or mutate the application's App. The
application selects prefix, order and middleware and calls `web.mount`. Mount
copies; the caller destroys the source Router and the App destroys its copy.

## ADR-C003 — services are application-owned

**ACCEPTED, 2026-07-22 (WP73).** Pools, clients and caches live in the
application's typed `App_State`. There is no Crystal registry, extension bag,
package-global service or hidden initializer. Creation, readiness and
destruction stay visible in the composition root.

## ADR-C004 — one repository and collection initially

**ACCEPTED, 2026-07-22 (WP73).** First-party Crystals share this repository
and the `crystals:` collection while the ecosystem is small. A package leaves
when native dependencies, license, maintainer, users or release cadence demand
independence. Crystals never live inside the core repository.

## ADR-C005 — compatibility is measured against commits

**ACCEPTED, 2026-07-22 (WP73).** Until stable tags exist, the compatibility
matrix names exact Odin and Uruquim commits and a verified platform. “Latest”
is not a reproducible dependency constraint.

## ADR-C006 — explicit public ledgers and independent gates

**ACCEPTED, 2026-07-22 (WP73).** Each package declares its own exports and
evidence. The repository gate compiles examples and tests, rejects internal
core imports/private access and carries a semantic negative control. Core's
62 + 2 ledger is neither copied nor increased by this repository.
