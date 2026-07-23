package main
import "core:fmt"
import "core:os"
import hc "crystals:http_client"
main :: proc() {
	target := os.args[1]
	ca := len(os.args) > 2 ? os.args[2] : ""
	c, _ := hc.open(hc.Config{max_conns = 2, connect_timeout_ms = 4000, request_timeout_ms = 4000, tls_ca_file = ca})
	defer hc.close(&c)
	resp, e := hc.get(&c, target)
	defer hc.response_destroy(&resp)
	fmt.printf("kind=%v status=%d detail=%q len(body)=%d\n", e.kind, resp.status, e.detail, len(resp.body))
}
