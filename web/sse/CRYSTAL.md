# crystals:web/sse

**Category:** Library + Request. **Status:** Experimental.

Server-Sent Events over the accepted Phase-7 public stream surface
(`web.stream`/`web.stream_send`/`web.stream_close`). It imports only
`uruquim:web` — never `web/internal`, never a backend — so SSE proves the core
streaming abstraction supports a real protocol with no privileged access.

`open(ctx) -> (web.Stream, bool)` detaches an SSE response with
`Content-Type: text/event-stream`; the handler then returns. `send(s, Event)`
encodes one event (event/id/retry/data, multi-line data safe) and enqueues it;
`comment(s, text)` sends a heartbeat; `last_event_id(ctx)` reads the
reconnection cursor. The application owns the `web.Stream` token and ends the
stream with `web.stream_close`.

| Question | Answer |
|---|---|
| Creator | `open` returns a `web.Stream` the core registry owns; the token is a value the caller holds. |
| Owner | The application owns the token and calls `web.stream_close`; the connection and queued bytes are core-owned. |
| Copying | `web.Stream` is a stale-safe value; a copy held past the stream's life refuses on send/close. |
| Request memory | `open`/`last_event_id` read the request; nothing is retained past the handler. Framing uses the temp allocator. |
| Capacity | One event frames to at most `MAX_EVENT_BYTES` (64 KiB); larger is `Too_Large`, sent nothing. The stream's bounded queue returns `Full`. |
| Threading | `send`/`comment` may be called from any thread, exactly as `web.stream_send`. |
| Failure | `Send_Result{Sent, Full, Closed, Too_Large}` — every path is typed; a stale token is `Closed`. |
| Teardown | `web.stream_close` writes the terminating chunk and retires the connection, exactly once. |

**Security.** A newline in `event`, `id` or a comment is flattened to a space,
so a field value cannot inject a second SSE line; `data` newlines become
separate `data:` fields (the grammar), never event terminators.

Rollback is deleting the import and the `open`/`send`/`comment` calls. No core
change is required; the core streaming surface predates this package.
