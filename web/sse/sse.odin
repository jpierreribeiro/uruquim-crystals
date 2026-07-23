// crystals:web/sse — Server-Sent Events over the accepted public stream surface.
//
// SSE proves the Phase-7 core abstraction supports a real protocol with NO
// privileged access: this package imports only `uruquim:web`, never
// `web/internal`, never the backend. It is a thin framing layer — `open` sets
// the one header SSE requires (`text/event-stream`) through `web.stream`'s
// public content-type parameter, `send` encodes one event and hands the bytes
// to `web.stream_send`, and the application owns the stream token and its
// lifetime exactly as the core defines them.
package sse

import web "uruquim:web"
import "core:strconv"
import "core:strings"

// The largest single framed event this package will send. An event over the
// cap is refused (`Too_Large`) rather than truncated or split — a bound with a
// typed result, per the Crystal contract's hot-path rule.
MAX_EVENT_BYTES :: 64 * 1024

// Event is one SSE message. Empty string / non-positive fields are omitted, so
// a bare `Event{data = "hi"}` frames as `data: hi\n\n`. `data` may contain
// newlines: each line is emitted as its own `data:` field, which is what the
// SSE grammar requires and what a hand-rolled encoder gets wrong.
Event :: struct {
	event: string, // the event type; omitted when empty
	id:    string, // the event id, echoed back as Last-Event-ID on reconnect
	data:  string, // the payload; multi-line safe
	retry: int,    // reconnection delay hint in ms; omitted when <= 0
}

// Send_Result mirrors `web.Stream_Send`, plus the framing refusal this layer
// adds. It is a distinct enum so a caller handles the encoder's bound without
// reaching into the core's.
Send_Result :: enum {
	Sent,
	Full,      // the stream's bounded queue refused it (web.Stream_Send.Full)
	Closed,    // the stream is closed or the token is stale
	Too_Large, // the framed event exceeded MAX_EVENT_BYTES; nothing was sent
}

// open detaches an SSE response on the current request's connection, setting
// `Content-Type: text/event-stream` so a browser `EventSource` accepts it.
// The handler then RETURNS; later code sends with `send`/`comment` and ends
// with `web.stream_close`. `ok` is false where there is no connection to
// detach (the in-memory transport) or the open-stream cap is reached.
open :: proc(ctx: ^web.Context) -> (s: web.Stream, ok: bool) {
	return web.stream(ctx, "text/event-stream")
}

// send encodes one event and enqueues it. Bounded and non-blocking: the frame
// is built in the temp allocator, size-checked, then copied into stream-owned
// storage by `web.stream_send`.
send :: proc(s: web.Stream, e: Event) -> Send_Result {
	b := strings.builder_make(context.temp_allocator)
	if len(e.event) > 0 {
		strings.write_string(&b, "event: ")
		write_single_line(&b, e.event)
		strings.write_byte(&b, '\n')
	}
	if len(e.id) > 0 {
		strings.write_string(&b, "id: ")
		write_single_line(&b, e.id)
		strings.write_byte(&b, '\n')
	}
	if e.retry > 0 {
		strings.write_string(&b, "retry: ")
		buf: [24]u8
		strings.write_string(&b, strconv.write_int(buf[:], i64(e.retry), 10))
		strings.write_byte(&b, '\n')
	}
	// data: one field per line, so an embedded newline cannot terminate the
	// event early (the field-injection bug of a naive encoder).
	if len(e.data) > 0 {
		rest := e.data
		for {
			nl := strings.index_byte(rest, '\n')
			if nl < 0 {
				strings.write_string(&b, "data: ")
				strings.write_string(&b, rest)
				strings.write_byte(&b, '\n')
				break
			}
			strings.write_string(&b, "data: ")
			strings.write_string(&b, rest[:nl])
			strings.write_byte(&b, '\n')
			rest = rest[nl + 1:]
		}
	}
	strings.write_byte(&b, '\n') // the blank line that terminates the event

	frame := strings.to_string(b)
	if len(frame) > MAX_EVENT_BYTES {
		return .Too_Large
	}
	return classify(web.stream_send(s, transmute([]u8)frame))
}

// comment sends an SSE comment line (`: text`), the conventional heartbeat that
// keeps proxies and clients from timing out an idle stream without delivering
// a data event. A newline in `text` is replaced by a space; a comment is a
// single line by grammar.
comment :: proc(s: web.Stream, text: string) -> Send_Result {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, ": ")
	write_single_line(&b, text)
	strings.write_string(&b, "\n\n")
	frame := strings.to_string(b)
	if len(frame) > MAX_EVENT_BYTES {
		return .Too_Large
	}
	return classify(web.stream_send(s, transmute([]u8)frame))
}

// last_event_id reads the reconnection cursor the client sends after a drop.
// The application decides what to replay from it; SSE only carries it.
last_event_id :: proc(ctx: ^web.Context) -> (value: string, ok: bool) {
	return web.header(ctx, "Last-Event-ID")
}

@(private)
classify :: proc(r: web.Stream_Send) -> Send_Result {
	switch r {
	case .Sent:   return .Sent
	case .Full:   return .Full
	case .Closed: return .Closed
	}
	return .Closed
}

// write_single_line writes `text` with any CR or LF replaced by a space, so a
// header-like field (event, id, comment) cannot inject a second SSE line.
@(private)
write_single_line :: proc(b: ^strings.Builder, text: string) {
	for i in 0 ..< len(text) {
		c := text[i]
		if c == '\n' || c == '\r' {
			strings.write_byte(b, ' ')
		} else {
			strings.write_byte(b, c)
		}
	}
}
