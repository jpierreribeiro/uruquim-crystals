package health_test

import "core:testing"
import health "crystals:web/health"
import web "uruquim:web"

@(test)
route_is_detached_and_mount_prefix_belongs_to_the_application :: proc(t: ^testing.T) {
	app := web.app()

	routes := health.routes()
	web.mount(&app, "/health", &routes)

	live := web.test_request(&app, .GET, "/health/live")
	testing.expect_value(t, live.status, web.Status.OK)
	testing.expect_value(t, live.body, "ok")

	unmounted := web.test_request(&app, .GET, "/live")
	testing.expect_value(t, unmounted.status, web.Status.Not_Found)

	web.destroy(&routes)
	web.destroy(&app)
}
