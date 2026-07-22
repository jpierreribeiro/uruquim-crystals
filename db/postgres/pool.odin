package postgres

import "core:sync"
import "core:time"

// Pool_Config bounds a connection pool. Every waiting path has a hard cap and a
// deadline; there is no unlimited waiter queue. The canonical deployment keeps
// max_conns below the server's Handler-lane capacity so a saturated pool fails
// fast for database work while health, shutdown and non-database work stay live.
Pool_Config :: struct {
	conn:               Config,
	// min_conns are opened at pool_open as a fail-closed readiness check.
	min_conns:          int,
	// max_conns is the hard cap on open connections. Must be >= 1.
	max_conns:          int,
	// max_idle connections are kept available; extras are closed on release.
	// 0 defaults to max_conns.
	max_idle:           int,
	// max_waiters caps threads blocked waiting for a connection. Beyond it,
	// acquire fails immediately with Pool_Exhausted. 0 defaults to a bound
	// derived from max_conns.
	max_waiters:        int,
	// acquire_timeout_ms bounds how long acquire waits. 0 defaults to
	// DEFAULT_ACQUIRE_TIMEOUT_MS; it is never unbounded.
	acquire_timeout_ms: int,
	// max_lifetime_ms recycles a connection older than this. 0 disables.
	max_lifetime_ms:    int,
	// max_idle_time_ms closes an idle connection unused this long. 0 disables.
	max_idle_time_ms:   int,
}

DEFAULT_ACQUIRE_TIMEOUT_MS :: 5_000

// Pool_Stats is a safe observability snapshot. It never contains a DSN,
// credential or SQL.
Pool_Stats :: struct {
	open:    int, // total open connections (idle + in use)
	idle:    int, // available connections
	in_use:  int, // borrowed connections
	waiters: int, // threads currently waiting for a connection
}

@(private)
Idle_Conn :: struct {
	conn:      Conn,
	last_used: time.Time,
}

// Pool is a hard-capped, thread-safe connection pool. The application creates it
// in App_State and destroys it with pool_close. A borrowed connection has one
// calling thread; a broken or transaction-uncertain connection is never returned
// to the available set.
Pool :: struct {
	_cfg:       Pool_Config,
	_mu:        sync.Mutex,
	_slot_free: sync.Cond,
	_idle:      [dynamic]Idle_Conn,
	_open:      int,
	_borrowed:  int,
	_waiters:   int,
	_closed:    bool,
}

// pool_open validates the configuration, opens min_conns as a fail-closed
// readiness check, and returns a ready pool. Any failure to open the initial
// connections closes what was opened and returns the typed error.
pool_open :: proc(cfg: Pool_Config, loc := #caller_location) -> (Pool, Error) {
	c := cfg
	if c.max_conns < 1 {
		return Pool{}, err(.Config_Invalid, "postgres.pool_open", loc)
	}
	if c.min_conns < 0 || c.min_conns > c.max_conns {
		return Pool{}, err(.Config_Invalid, "postgres.pool_open", loc)
	}
	if c.max_idle <= 0 {
		c.max_idle = c.max_conns
	}
	if c.max_waiters <= 0 {
		c.max_waiters = c.max_conns * 8 + 8
	}
	if c.acquire_timeout_ms <= 0 {
		c.acquire_timeout_ms = DEFAULT_ACQUIRE_TIMEOUT_MS
	}
	if k := validate_config(c.conn); k != .None {
		return Pool{}, err(k, "postgres.pool_open", loc)
	}

	p := Pool{_cfg = c}
	p._idle = make([dynamic]Idle_Conn)
	now := time.now()
	for _ in 0 ..< c.min_conns {
		conn, e := open(c.conn, loc)
		if is_err(e) {
			pool_close(&p)
			return Pool{}, e
		}
		append(&p._idle, Idle_Conn{conn = conn, last_used = now})
		p._open += 1
	}
	return p, Error{}
}

// acquire borrows a connection within the acquire deadline. When the pool is
// saturated it either waits up to the deadline or, if the bounded waiter set is
// already full, returns Pool_Exhausted immediately. The caller must release the
// returned connection.
acquire :: proc(p: ^Pool, loc := #caller_location) -> (Conn, Error) {
	sync.mutex_lock(&p._mu)
	defer sync.mutex_unlock(&p._mu)

	start := time.now()
	budget := time.Duration(p._cfg.acquire_timeout_ms) * time.Millisecond

	for {
		if p._closed {
			return Conn{}, err(.Closed, "postgres.acquire", loc)
		}

		// Reuse a healthy idle connection, discarding expired or broken ones.
		for len(p._idle) > 0 {
			ic := pop(&p._idle)
			if is_broken(&ic.conn) || conn_expired(p, &ic.conn) || idle_expired(p, ic) {
				close(&ic.conn)
				p._open -= 1
				continue
			}
			p._borrowed += 1
			return ic.conn, Error{}
		}

		// Open a new connection if under the hard cap. The connect I/O runs
		// without the lock; the slot is reserved first so max_conns holds.
		if p._open < p._cfg.max_conns {
			p._open += 1
			sync.mutex_unlock(&p._mu)
			conn, e := open(p._cfg.conn, loc)
			sync.mutex_lock(&p._mu)
			if is_err(e) {
				p._open -= 1
				sync.cond_signal(&p._slot_free)
				return Conn{}, e
			}
			p._borrowed += 1
			return conn, Error{}
		}

		// Saturated: wait within the deadline and the bounded waiter set.
		if p._waiters >= p._cfg.max_waiters {
			return Conn{}, err(.Pool_Exhausted, "postgres.acquire", loc)
		}
		remaining := budget - time.since(start)
		if remaining <= 0 {
			return Conn{}, err(.Pool_Exhausted, "postgres.acquire", loc)
		}
		p._waiters += 1
		signalled := sync.cond_wait_with_timeout(&p._slot_free, &p._mu, remaining)
		p._waiters -= 1
		if !signalled {
			return Conn{}, err(.Pool_Exhausted, "postgres.acquire", loc)
		}
	}
}

// release returns a connection to the pool, or closes it when the pool is
// closed, the connection is broken or transaction-uncertain, it has outlived its
// lifetime, or the idle set is already full. A broken connection is never made
// available again.
release :: proc(p: ^Pool, c: ^Conn) {
	sync.mutex_lock(&p._mu)
	defer sync.mutex_unlock(&p._mu)

	p._borrowed -= 1
	discard := p._closed || is_broken(c) || conn_expired(p, c) || len(p._idle) >= p._cfg.max_idle
	if discard {
		close(c)
		p._open -= 1
	} else {
		append(&p._idle, Idle_Conn{conn = c^, last_used = time.now()})
	}
	sync.cond_signal(&p._slot_free)
}

// pool_close rejects new borrows, closes every idle connection now, and wakes all
// waiters so they observe the closed pool. Connections still borrowed are closed
// when their holders release them.
pool_close :: proc(p: ^Pool) {
	sync.mutex_lock(&p._mu)
	p._closed = true
	for len(p._idle) > 0 {
		ic := pop(&p._idle)
		close(&ic.conn)
		p._open -= 1
	}
	sync.cond_broadcast(&p._slot_free)
	no_borrowers := p._borrowed == 0
	sync.mutex_unlock(&p._mu)

	if no_borrowers {
		delete(p._idle)
	}
}

// pool_stats returns a safe snapshot for observability.
pool_stats :: proc(p: ^Pool) -> Pool_Stats {
	sync.mutex_lock(&p._mu)
	defer sync.mutex_unlock(&p._mu)
	return Pool_Stats{open = p._open, idle = len(p._idle), in_use = p._borrowed, waiters = p._waiters}
}

@(private)
conn_expired :: proc(p: ^Pool, c: ^Conn) -> bool {
	if p._cfg.max_lifetime_ms <= 0 {
		return false
	}
	age := time.since(c._opened_at)
	return age > time.Duration(p._cfg.max_lifetime_ms) * time.Millisecond
}

@(private)
idle_expired :: proc(p: ^Pool, ic: Idle_Conn) -> bool {
	if p._cfg.max_idle_time_ms <= 0 {
		return false
	}
	idle := time.since(ic.last_used)
	return idle > time.Duration(p._cfg.max_idle_time_ms) * time.Millisecond
}
