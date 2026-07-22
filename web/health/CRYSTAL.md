# crystals:web/health

**Category:** Route. **Status:** Experimental.

`routes() -> web.Router` creates a detached router containing `GET /live`.
The application selects its mount prefix.

| Question | Answer |
|---|---|
| Creator | `routes` creates the Router by value. |
| Owner | Caller always owns the Router; mount copies routes into the App. Destroy both exactly once. |
| Copying | Do not copy after registration; pass by pointer to `web.mount`. |
| Request memory | Handler owns no state and retains no request view. |
| Capacity | One fixed route, no dynamic collection or queue. |
| Threading | Handler is immutable/stateless and may run concurrently. |
| Failure | Core registration/mount failure poisons the destination fail-closed. |
| Teardown | `web.destroy(&router)` releases the source; App destruction releases the mounted copy. |

Rollback is deleting the import, `routes` call and mount. No core change is
required.
