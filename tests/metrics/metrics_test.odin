// metrics Crystal corpus: the derived per-kind counter, the refused-connections
// scalar, the canonical exposition structure, and — the invariant that matters —
// that no raw request path reaches the output.
//
// One test only: the aggregator is a process-global registry (web.observe carries
// no user pointer), so a single flow avoids cross-test interference on the shared
// counters.
package test_metrics

import "core:log"
import "core:strings"
import "core:testing"
import metrics "crystals:web/metrics"
import web "uruquim:web"

// A handler that returns WITHOUT responding — the framework commits a 500 and
// fires the observer with kind = No_Response_Committed (WP8).
@(private)
no_response :: proc(ctx: ^web.Context) {}

// A logger that DROPS the framework's own deliberately-triggered error
// diagnostic (which the test runner would otherwise count as a failure) but
// forwards everything else — including testing.expect failures — to the real
// logger, so this test can still fail. (A blanket nil_logger cannot.)
@(private)
Filtered :: struct {
	prev: log.Logger,
}

@(private)
filtered_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	f := (^Filtered)(data)
	if level == .Error && strings.contains(text, "uruquim:") {
		return
	}
	if f.prev.procedure != nil {
		f.prev.procedure(f.prev.data, level, text, options, location)
	}
}

@(test)
metrics_counts_framework_errors_and_refused_without_leaking_paths :: proc(t: ^testing.T) {
	filt := Filtered{prev = context.logger}
	context.logger = log.Logger {
		procedure    = filtered_proc,
		data         = &filt,
		lowest_level = context.logger.lowest_level,
		options      = context.logger.options,
	}

	app := web.app()
	defer web.destroy(&app)

	metrics.install(&app)

	// A route whose raw path we can later prove never appears in the exposition,
	// plus the metrics endpoint under its own prefix.
	web.get(&app, "/boom/secret-path", no_response)
	mr := metrics.routes()
	defer web.destroy(&mr)
	web.mount(&app, "/obs", &mr)

	// Trigger exactly one framework error.
	boom := web.test_request(&app, .GET, "/boom/secret-path")
	testing.expect_value(t, boom.status, web.Status.Internal_Server_Error)

	// Scrape.
	scrape := web.test_request(&app, .GET, "/obs/metrics")
	testing.expect_value(t, scrape.status, web.Status.OK)
	body := scrape.body

	// The failure was counted, by closed-enum kind.
	testing.expectf(
		t,
		strings.contains(body, "uruquim_framework_errors_total{kind=\"No_Response_Committed\"} 1"),
		"the framework error is counted by kind; body was:\n%s",
		body,
	)
	// The canonical exposition structure is present.
	testing.expect(t, strings.contains(body, "# TYPE uruquim_framework_errors_total counter"), "has a TYPE line")
	testing.expect(t, strings.contains(body, "uruquim_refused_connections_total"), "renders the refused-connections scalar")

	// The invariant: the raw request path must NEVER reach the metrics output.
	testing.expect(t, !strings.contains(body, "secret-path"), "the raw request path must not leak into the exposition")
}
