package health

import web "uruquim:web"

// routes returns a detached, application-independent liveness route. The
// caller chooses the prefix and transfers ownership with web.mount.
routes :: proc() -> web.Router {
	r := web.router()
	web.get(&r, "/live", live)
	return r
}

@(private)
live :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}
