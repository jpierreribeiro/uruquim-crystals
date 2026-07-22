package main

import health "crystals:web/health"
import web "uruquim:web"

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	routes := health.routes()
	defer web.destroy(&routes)
	web.mount(&app, "/health", &routes)

	web.serve(&app, 8080)
}
