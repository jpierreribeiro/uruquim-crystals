# Crystal contract

## Dependency

```text
application → crystals → public uruquim packages
uruquim core ↛ crystals
```

There is no discovery, plugin ABI, registry, import side effect or automatic
initialization. Removing a Crystal means removing its import and explicit
composition calls.

## Ownership questions

Every package answers:

1. who creates each long-lived value;
2. who owns and destroys it;
3. whether it may be copied or shared;
4. how capacity is bounded and exhaustion behaves;
5. which calls are thread-safe;
6. which typed failures cross its boundary.

Request views and `^web.Context` never escape a request. A Crystal never reads
`.private`, imports `web/internal`, retains `^web.App`, calls `web.serve`, runs
migrations at server boot or stores services in package globals.

## Categories

- **Library:** transport-free computation with no app-lived resource.
- **Service:** transport-free app-lived resource, owned by `App_State`.
- **Request:** handler/extractor that touches a request and owns nothing beyond
  it.
- **Route:** constructs a detached Router for the application to mount.
- **Tool:** separate executable, absent from the server process.

If a package fits two categories, split it. In particular, PostgreSQL remains
a Service and HTTP validation remains a thin Request adapter.

## Public and hot-path rules

Fundamental names are conventional and searchable. Public growth pays a
package-local ledger entry, compiling example, behavioural test, ownership
note, dependency review and rollback. Reflection and configuration parsing,
when justified, happen before the hot path and fail closed. Queues, pools,
messages and retries always have a numeric bound and an exhaustion result.
