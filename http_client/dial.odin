package http_client

import "core:c"
import "core:net"
import "core:sys/posix"

// dial_timeout establishes a TCP connection to an IPv4 endpoint with a hard
// connect deadline. core:net's dial_tcp connects with a blocking connect() and
// no timeout; a firewalled or black-holed host would hang past every budget. So
// the connect is done here with a non-blocking connect() plus poll(), which is
// the portable POSIX way to bound the handshake. On success the socket is
// returned to blocking mode and handed back as a net.TCP_Socket for the rest of
// the exchange (send/recv, or SSL_set_fd).
//
// Only IPv4 is handled; an IPv6 endpoint returns .Invalid_Url (a recorded
// limitation of the bridge era, closed at the core:net/http transition).
@(private)
dial_timeout :: proc(endpoint: net.Endpoint, timeout_ms: int) -> (net.TCP_Socket, Error_Kind) {
	ip4, is_v4 := endpoint.address.(net.IP4_Address)
	if !is_v4 {
		return {}, .Invalid_Url
	}

	fd := posix.socket(.INET, .STREAM)
	if fd == posix.FD(-1) {
		return {}, .Connect_Failed
	}

	// Non-blocking for the connect so poll() bounds the handshake.
	flags := posix.fcntl(fd, .GETFL)
	posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK)

	sa := posix.sockaddr_in {
		sin_family = .INET,
		sin_port   = in_port_t_from(endpoint.port),
		sin_addr   = posix.in_addr{s_addr = transmute(posix.in_addr_t)ip4},
	}

	connected := false
	res := posix.connect(fd, cast(^posix.sockaddr)&sa, socklen_of_sockaddr_in())
	if res == .OK {
		connected = true
	} else if posix.errno() == .EINPROGRESS {
		pfd := posix.pollfd{fd = fd, events = {.OUT}}
		n := posix.poll(&pfd, 1, c.int(timeout_ms))
		if n == 0 {
			posix.close(fd)
			return {}, .Connect_Timeout
		}
		if n < 0 || .ERR in pfd.revents || .HUP in pfd.revents || .NVAL in pfd.revents {
			posix.close(fd)
			return {}, .Connect_Failed
		}
		// Writable: confirm the connect actually succeeded via SO_ERROR.
		soerr: c.int
		slen := socklen_of_c_int()
		if posix.getsockopt(fd, c.int(posix.SOL_SOCKET), .ERROR, &soerr, &slen) != .OK || soerr != 0 {
			posix.close(fd)
			return {}, .Connect_Failed
		}
		connected = true
	} else {
		posix.close(fd)
		return {}, .Connect_Failed
	}

	if !connected {
		posix.close(fd)
		return {}, .Connect_Failed
	}

	// Back to blocking; per-request timeouts are enforced with socket receive/
	// send timeouts by the caller.
	posix.fcntl(fd, .SETFL, flags)
	return net.TCP_Socket(fd), .None
}

@(private)
in_port_t_from :: proc(port: int) -> posix.in_port_t {
	return posix.in_port_t(u16(port))
}

@(private)
socklen_of_sockaddr_in :: proc() -> posix.socklen_t {
	return posix.socklen_t(size_of(posix.sockaddr_in))
}

@(private)
socklen_of_c_int :: proc() -> posix.socklen_t {
	return posix.socklen_t(size_of(c.int))
}
