package http_client

import "base:runtime"
import "core:net"
import "core:sync"
import "core:time"

// Stats is a safe observability snapshot. It never contains a URL, host, or any
// request-derived bytes.
Stats :: struct {
	in_flight: int, // slots currently held by active requests
	waiters:   int, // callers currently waiting for a slot
	draining:  bool, // close/drain has begun
}

// Client is a hard-capped, thread-safe outbound HTTP client. The application
// creates it in App_State and destroys it with close. Its bound is a counting
// pool of at most max_conns simultaneous in-flight requests (the vendored
// bridge closes each connection after its response, so the bound is on
// concurrency, not on kept-alive sockets). A saturated pool fails fast with the
// typed Pool_Exhausted rather than growing or blocking without bound.
Client :: struct {
	_cfg:       Config,
	_mu:        sync.Mutex,
	_slot_free: sync.Cond,
	_in_flight: int,
	_waiters:   int,
	_closed:    bool,
	_draining:  bool,
	// _active tracks the sockets of in-flight requests so drain can shut them
	// down and unblock a thread stuck in a read.
	_active:    map[net.TCP_Socket]bool,
}

// open validates the configuration and returns a ready client. It opens no
// sockets; the pool is a concurrency limiter, not a warm connection cache.
open :: proc(cfg: Config, loc := #caller_location) -> (Client, Error) {
	c, k := normalize_config(cfg)
	if k != .None {
		return Client{}, err(k, "http_client.open", loc)
	}
	cl := Client{_cfg = c}
	cl._active = make(map[net.TCP_Socket]bool)
	return cl, Error{}
}

// close begins a drain: it rejects new requests, shuts down every in-flight
// socket so blocked reads return, and wakes all waiters. In-flight requests
// observe the drain and return Canceled. It then waits (bounded by the acquire
// timeout) for the in-flight count to reach zero before freeing state.
close :: proc(c: ^Client) {
	sync.mutex_lock(&c._mu)
	if c._closed {
		sync.mutex_unlock(&c._mu)
		return
	}
	c._closed = true
	c._draining = true
	// Shut down every in-flight socket; a read blocked on it returns instead of
	// hanging past the drain.
	for sock in c._active {
		net.shutdown(sock, net.Shutdown_Manner.Both)
	}
	sync.cond_broadcast(&c._slot_free)

	// Wait, bounded, for in-flight requests to drain.
	deadline := time.tick_now()
	budget := time.Duration(c._cfg.acquire_timeout_ms) * time.Millisecond
	for c._in_flight > 0 {
		remaining := budget - time.tick_since(deadline)
		if remaining <= 0 {
			break
		}
		sync.cond_wait_with_timeout(&c._slot_free, &c._mu, remaining)
	}
	sync.mutex_unlock(&c._mu)

	delete(c._active)
	c._active = nil
}

// stats returns a safe snapshot for observability.
stats :: proc(c: ^Client) -> Stats {
	sync.mutex_lock(&c._mu)
	defer sync.mutex_unlock(&c._mu)
	return Stats{in_flight = c._in_flight, waiters = c._waiters, draining = c._draining}
}

// acquire_slot borrows one in-flight slot within the acquire deadline. When the
// pool is saturated it waits up to the deadline or, if the bounded waiter set is
// already full, returns Pool_Exhausted immediately. A draining/closed client
// returns Canceled/Closed. The caller must release_slot.
@(private)
acquire_slot :: proc(c: ^Client, budget: time.Duration, loc: runtime.Source_Code_Location) -> Error {
	sync.mutex_lock(&c._mu)
	defer sync.mutex_unlock(&c._mu)

	start := time.tick_now()
	for {
		if c._closed {
			return err(.Closed, "http_client.acquire", loc)
		}
		if c._draining {
			return err(.Canceled, "http_client.acquire", loc)
		}
		if c._in_flight < c._cfg.max_conns {
			c._in_flight += 1
			return Error{}
		}
		if c._waiters >= c._cfg.max_waiters {
			return err(.Pool_Exhausted, "http_client.acquire", loc)
		}
		remaining := budget - time.tick_since(start)
		if remaining <= 0 {
			return err(.Pool_Exhausted, "http_client.acquire", loc)
		}
		c._waiters += 1
		signalled := sync.cond_wait_with_timeout(&c._slot_free, &c._mu, remaining)
		c._waiters -= 1
		if !signalled && time.tick_since(start) >= budget {
			return err(.Pool_Exhausted, "http_client.acquire", loc)
		}
	}
}

@(private)
release_slot :: proc(c: ^Client) {
	sync.mutex_lock(&c._mu)
	c._in_flight -= 1
	sync.cond_signal(&c._slot_free)
	sync.mutex_unlock(&c._mu)
}

// register_active records an in-flight socket so a drain can shut it down.
// Returns false if a drain is already in progress, in which case the caller must
// abandon the request as Canceled.
@(private)
register_active :: proc(c: ^Client, sock: net.TCP_Socket) -> bool {
	sync.mutex_lock(&c._mu)
	defer sync.mutex_unlock(&c._mu)
	if c._draining {
		return false
	}
	c._active[sock] = true
	return true
}

@(private)
unregister_active :: proc(c: ^Client, sock: net.TCP_Socket) {
	sync.mutex_lock(&c._mu)
	delete_key(&c._active, sock)
	sync.mutex_unlock(&c._mu)
}

@(private)
is_draining :: proc(c: ^Client) -> bool {
	sync.mutex_lock(&c._mu)
	defer sync.mutex_unlock(&c._mu)
	return c._draining
}
