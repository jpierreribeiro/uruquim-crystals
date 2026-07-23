// SSE Crystal — framing correctness (pure, no socket) and the end-to-end wire
// path through web.serve, including Last-Event-ID reconnection.
package test_sse

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "uruquim:web"
import sse "crystals:web/sse"

// --- pure framing: the properties a hand-rolled encoder gets wrong ----------

Shared :: struct {
	tok:    web.Stream,
	opened: sync.Sema,
	ok:     bool,
	lastid: string,
	hadid:  bool,
}

g: ^Shared

@(private)
handler :: proc(ctx: ^web.Context) {
	g.lastid, g.hadid = sse.last_event_id(ctx)
	s, ok := sse.open(ctx)
	g.tok = s
	g.ok = ok
	sync.sema_post(&g.opened)
}

Server :: struct {app: web.App, port: int, thread: ^thread.Thread}

@(private)
serve_thread :: proc(s: ^Server) {web.serve(&s.app, s.port)}

@(private)
start :: proc(s: ^Server, port: int) -> bool {
	s.port = port
	s.app = web.app()
	web.get(&s.app, "/sse", handler)
	s.thread = thread.create_and_start_with_poly_data(s, serve_thread)
	for _ in 0 ..< 300 {
		sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127,0,0,1}, port = port})
		if err == nil {net.close(sock); return true}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

@(private)
stop :: proc(s: ^Server) {
	web.stop(&s.app)
	if s.thread != nil {thread.join(s.thread); thread.destroy(s.thread); s.thread = nil}
	web.destroy(&s.app)
}

@(private)
dial :: proc(port: int) -> (net.TCP_Socket, bool) {
	for _ in 0 ..< 100 {
		sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127,0,0,1}, port = port})
		if err == nil {return sock, true}
		time.sleep(2 * time.Millisecond)
	}
	return {}, false
}

@(private)
recv_until :: proc(sock: net.TCP_Socket, b: ^strings.Builder, marker: string, timeout: time.Duration) -> bool {
	net.set_option(sock, .Receive_Timeout, timeout)
	buf: [2048]u8
	for {
		if strings.contains(strings.to_string(b^), marker) {return true}
		n, e := net.recv_tcp(sock, buf[:])
		if n > 0 {strings.write_bytes(b, buf[:n])}
		if n == 0 || e != nil {return strings.contains(strings.to_string(b^), marker)}
	}
}

@(test)
sse_frames_arrive_with_event_stream_content_type_and_correct_grammar :: proc(t: ^testing.T) {
	shared: Shared
	g = &shared
	srv: Server
	testing.expect(t, start(&srv, 52070), "server starts")
	defer stop(&srv)

	sock, ok := dial(52070)
	testing.expect(t, ok)
	defer net.close(sock)
	_, _ = net.send_tcp(sock, transmute([]u8)string("GET /sse HTTP/1.1\r\nHost: x\r\n\r\n"))
	testing.expect(t, sync.sema_wait_with_timeout(&shared.opened, 3 * time.Second))
	testing.expect(t, shared.ok, "sse.open must succeed on a real connection")

	wire: strings.Builder
	strings.builder_init(&wire, context.temp_allocator)
	testing.expect(t, recv_until(sock, &wire, "\r\n\r\n", 3 * time.Second), "head commits")
	head := strings.to_string(wire)
	testing.expect(t, strings.contains(head, "text/event-stream"), "EventSource requires this content type")

	// A multi-line data event with an id and event type.
	testing.expect_value(t, sse.send(shared.tok, sse.Event{event = "tick", id = "42", data = "line1\nline2"}), sse.Send_Result.Sent)
	testing.expect(t, recv_until(sock, &wire, "line2", 3 * time.Second), "the event arrives")
	got := strings.to_string(wire)
	// Grammar: event/id/data-per-line, terminated by a blank line.
	testing.expect(t, strings.contains(got, "event: tick\r\n" ) || strings.contains(got, "event: tick\n"), "event field present")
	testing.expect(t, strings.contains(got, "id: 42"), "id field present")
	testing.expect(t, strings.contains(got, "data: line1"), "first data line")
	testing.expect(t, strings.contains(got, "data: line2"), "second data line as its own field (multi-line safe)")

	// A heartbeat comment.
	testing.expect_value(t, sse.comment(shared.tok, "ping"), sse.Send_Result.Sent)
	testing.expect(t, recv_until(sock, &wire, ": ping", 3 * time.Second), "the comment heartbeat arrives")

	web.stream_close(shared.tok)
}

@(test)
sse_reads_last_event_id_for_reconnection :: proc(t: ^testing.T) {
	shared: Shared
	g = &shared
	srv: Server
	testing.expect(t, start(&srv, 52071), "server starts")
	defer stop(&srv)

	sock, ok := dial(52071)
	testing.expect(t, ok)
	defer net.close(sock)
	// A reconnecting client replays its cursor in the Last-Event-ID header.
	_, _ = net.send_tcp(sock, transmute([]u8)string("GET /sse HTTP/1.1\r\nHost: x\r\nLast-Event-ID: 42\r\n\r\n"))
	testing.expect(t, sync.sema_wait_with_timeout(&shared.opened, 3 * time.Second))
	testing.expect(t, shared.hadid, "the reconnection cursor must be readable")
	testing.expect_value(t, shared.lastid, "42")
	web.stream_close(shared.tok)
}

@(test)
sse_injection_is_neutralised :: proc(t: ^testing.T) {
	// A newline in event/id must not inject a second SSE line; data newlines
	// become separate data fields, never event terminators. Proven on the wire.
	shared: Shared
	g = &shared
	srv: Server
	testing.expect(t, start(&srv, 52072), "server starts")
	defer stop(&srv)
	sock, ok := dial(52072)
	testing.expect(t, ok)
	defer net.close(sock)
	_, _ = net.send_tcp(sock, transmute([]u8)string("GET /sse HTTP/1.1\r\nHost: x\r\n\r\n"))
	testing.expect(t, sync.sema_wait_with_timeout(&shared.opened, 3 * time.Second))
	wire: strings.Builder
	strings.builder_init(&wire, context.temp_allocator)
	testing.expect(t, recv_until(sock, &wire, "\r\n\r\n", 3 * time.Second))
	// An id carrying a newline + a forged "data:" must be flattened to one line.
	testing.expect_value(t, sse.send(shared.tok, sse.Event{id = "1\ndata: forged", data = "ok"}), sse.Send_Result.Sent)
	testing.expect(t, recv_until(sock, &wire, "data: ok", 3 * time.Second))
	got := strings.to_string(wire)
	testing.expect(t, !strings.contains(got, "id: 1\r\ndata: forged"), "a newline in id must not inject a second field")
	testing.expect(t, !strings.contains(got, "id: 1\ndata: forged"), "a newline in id must not inject a second field")
	web.stream_close(shared.tok)
}
