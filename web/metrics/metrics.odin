// The metrics Composition Crystal (Phase 7.5 Track A / A4).
//
// It renders the core's observability surface as Prometheus exposition text.
// That surface is deliberately tiny (`web/observability.odin`: the framework
// exports no metrics abstraction, only the raw signals): a PUSH observer that
// fires a closed `web.Framework_Event` per framework-detected failure, and a
// PULL scalar `web.refused_connections()`. This Crystal aggregates the push
// events into per-kind counters and, on scrape, renders them plus the pull
// scalar as one canonical `text/plain` exposition.
//
// Redaction (WP20) is preserved by construction, not by filtering: the only
// datum this Crystal reads from an event is `event.kind` — a member of the
// closed `web.Framework_Error` enum. It never reads `event.route`'s bytes, never
// a path, never a request byte, so no request-derived string can reach the
// output. The exposition is therefore BOUNDED: exactly one series per
// `Framework_Error` member (minus `None`) plus one scalar — a cardinality fixed
// at compile time by the enum, independent of traffic.
//
// One registry per process. `web.observe` carries no user pointer (an observer
// is a bare `proc(event)`), so the aggregator must be package state — which
// matches metrics being process-global anyway (`refused_connections()` already
// is). `install` points the App's single observer at this Crystal.
package metrics

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import web "uruquim:web"

// The derived per-kind failure counts. An enumerated array indexed by the closed
// error enum, so a new `Framework_Error` member is a compile-time-sized new
// series, never an unbounded label. Incremented atomically off the dispatch
// path; read atomically on scrape.
@(private)
g_counts: [web.Framework_Error]u64

// install points the App's framework-error observer at this Crystal. Call once,
// before `web.serve`. `web.observe` keeps only the last observer, so installing
// again simply re-points it here.
install :: proc(a: ^web.App) {
	web.observe(a, on_framework_event)
}

@(private)
on_framework_event :: proc(event: web.Framework_Event) {
	// The ONLY field read is the closed-enum kind. Never `event.route` (a string),
	// never a path, never a request byte — so nothing request-derived is retained.
	// Atomic so concurrent Handler lanes increment without a lock.
	intrinsics.atomic_add(&g_counts[event.kind], 1)
}

// routes returns a detached router exposing GET /metrics as Prometheus text. The
// caller chooses the prefix and transfers ownership with `web.mount`, exactly
// like the health Crystal.
routes :: proc() -> web.Router {
	r := web.router()
	web.get(&r, "/metrics", render)
	return r
}

@(private)
render :: proc(ctx: ^web.Context) {
	b := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&b)

	strings.write_string(
		&b,
		"# HELP uruquim_framework_errors_total Framework-detected failures, by closed-enum kind.\n",
	)
	strings.write_string(&b, "# TYPE uruquim_framework_errors_total counter\n")
	for kind in web.Framework_Error {
		if kind == .None {
			continue
		}
		n := intrinsics.atomic_load(&g_counts[kind])
		// `%v` on the enum renders its member name — a safe, low-cardinality
		// label (no request bytes). Members are plain identifiers, so no
		// Prometheus label-value escaping is required.
		fmt.sbprintf(&b, "uruquim_framework_errors_total{{kind=\"%v\"}} %d\n", kind, n)
	}

	strings.write_string(
		&b,
		"# HELP uruquim_refused_connections_total Connections refused for admission since start.\n",
	)
	strings.write_string(&b, "# TYPE uruquim_refused_connections_total counter\n")
	fmt.sbprintf(&b, "uruquim_refused_connections_total %d\n", web.refused_connections())

	// text/plain; charset=utf-8 — the exposition media type Prometheus scrapers
	// accept. The synchronous dump is bounded, so no streaming is needed.
	web.text(ctx, .OK, strings.to_string(b))
}
