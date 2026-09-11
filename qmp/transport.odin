// SPDX-License-Identifier: BSD-2-Clause
//
// transport - pluggable connection backends for the QMP client.
//
// The QMP protocol logic (framing, JSON, deadlines) is transport-agnostic: it
// only ever needs a connected, pollable file descriptor. This package provides
// that seam. It is built exclusively on `core:sys/posix`, so a single code path
// covers Linux, macOS and the BSDs (FreeBSD/NetBSD/OpenBSD) — every syscall
// used here has a uniform POSIX signature and the per-OS differences (socket
// address layouts, errno / O_NONBLOCK values) are already absorbed by the
// posix package's `#+build` branches.
//
// The abstraction is an interface (a data pointer + a vtable of two procs):
// `connect` establishes the connection (honouring a deadline) and returns the
// fd; `close` releases it.

package qmp

import "core:net"
import "core:sys/posix"
import "core:time"

// ---------------------------------------------------------------------------
// Transport interface (vtable)
// ---------------------------------------------------------------------------

/// A connection backend. `data` points at the backend's state; the two procs
/// are the vtable. Obtain one from `unix_transport()` or `tcp_transport()`.
Transport :: struct {
	data:    rawptr,
	connect: proc(data: rawptr, deadline: time.Time) -> (fd: posix.FD, err: Error),
	close:   proc(data: rawptr, fd: posix.FD),
}

// ---------------------------------------------------------------------------
// Shared connect helper
// ---------------------------------------------------------------------------

/// Set O_NONBLOCK on an fd (POSIX: via fcntl GETFL/SETFL). Returns false on error.
_posix_set_nonblocking :: proc(fd: posix.FD) -> bool {
	flags := posix.fcntl(fd, .GETFL)
	if flags == -1 {
		return false
	}
	fl := transmute(posix.O_Flags)i32(flags)
	fl += {.NONBLOCK}
	return posix.fcntl(fd, .SETFL, fl) != -1
}

/// Complete a non-blocking connect: wait for writability up to `deadline`,
/// then verify via SO_ERROR (the only reliable way to learn a non-blocking
/// connect's result). Returns .Timeout / .Connect_Failed on failure.
_transport_finish_connect :: proc(fd: posix.FD, deadline: time.Time) -> Error {
	pfd := posix.pollfd{fd = fd, events = {.OUT}}
	n := posix.poll(&pfd, 1, _ms_until(deadline))
	if n < 0 {
		return .Connect_Failed
	}
	if n == 0 {
		return .Timeout
	}
	// Verify the connect actually succeeded (revents alone are ambiguous).
	// SOL_SOCKET is a plain constant (1 on Linux, 0xffff on BSD); the option
	// level is passed as c.int.
	serr: i32
	slen := posix.socklen_t(size_of(serr))
	if posix.getsockopt(fd, posix.SOL_SOCKET, .ERROR, &serr, &slen) != .OK || serr != 0 {
		return .Connect_Failed
	}
	return .None
}

/// Shutdown + close an fd, ignoring errors.
_transport_close_fd :: proc(fd: posix.FD) {
	posix.shutdown(fd, .RDWR)
	posix.close(fd)
}

// ---------------------------------------------------------------------------
// Unix domain socket transport
// ---------------------------------------------------------------------------

_Unix_Transport :: struct {
	path:     [108]u8, // kernel max; BSD/macOS use only the first 104.
	path_len: int,
}

/// Create a transport that connects to a QMP Unix socket at `socket_path`.
/// Returns false if the path is empty or too long for a sockaddr_un on this OS.
unix_transport :: proc(t: ^Transport, socket_path: string) -> bool {
	limit := 104 when ODIN_OS != .Linux else 108
	if len(socket_path) == 0 || len(socket_path) > limit {
		return false
	}
	ut := new(_Unix_Transport)
	ut.path_len = len(socket_path)
	for i in 0 ..< len(socket_path) {
		ut.path[i] = socket_path[i]
	}
	t.data = ut
	t.connect = _unix_connect
	t.close = _unix_close
	return true
}

_unix_connect :: proc(data: rawptr, deadline: time.Time) -> (posix.FD, Error) {
	ut := cast(^_Unix_Transport)data

	fd := posix.socket(.UNIX, .STREAM, .IP)
	if fd == -1 {
		return 0, .Connect_Failed
	}
	if !_posix_set_nonblocking(fd) {
		posix.close(fd)
		return 0, .Connect_Failed
	}

	// sockaddr_un differs per OS (BSD/macOS have a leading sun_len and a
	// 104-byte path; Linux has neither and a 108-byte path). The posix package
	// already picked the right layout for the build target.
	addr: posix.sockaddr_un
	when ODIN_OS != .Linux {
		addr.sun_len = u8(size_of(posix.sockaddr_un))
	}
	addr.sun_family = .UNIX
	for i in 0 ..< ut.path_len {
		addr.sun_path[i] = ut.path[i]
	}

	res := posix.connect(fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr)))
	if res == .OK {
		return fd, .None // completed immediately
	}
	if posix.errno() != .EINPROGRESS {
		posix.close(fd)
		return 0, .Connect_Failed
	}
	if ferr := _transport_finish_connect(fd, deadline); ferr != .None {
		posix.close(fd)
		return 0, ferr
	}
	return fd, .None
}

_unix_close :: proc(data: rawptr, fd: posix.FD) {
	_transport_close_fd(fd)
	free(cast(^_Unix_Transport)data)
}

// ---------------------------------------------------------------------------
// TCP transport
// ---------------------------------------------------------------------------

_TCP_Transport :: struct {
	endpoint: net.Endpoint,
}

/// Create a transport that connects to a QMP TCP endpoint ("host:port", e.g.
/// "127.0.0.1:4444"). Returns false if the endpoint cannot be parsed.
///
/// NOTE: QEMU only speaks QMP over TCP when started with e.g.
/// `-qmp tcp:127.0.0.1:4444,server,nowait`.
tcp_transport :: proc(t: ^Transport, endpoint_str: string) -> bool {
	ep, ok := net.parse_endpoint(endpoint_str)
	if !ok || ep.port == 0 {
		return false
	}
	tt := new(_TCP_Transport)
	tt.endpoint = ep
	t.data = tt
	t.connect = _tcp_connect
	t.close = _tcp_close
	return true
}

_tcp_connect :: proc(data: rawptr, deadline: time.Time) -> (posix.FD, Error) {
	tt := cast(^_TCP_Transport)data

	// Build the concrete sockaddr for the endpoint's family, then connect.
	// The connect call needs the matching sockaddr_in / sockaddr_in6 (sizes
	// differ); BSD/macOS variants carry a leading length field.
	_, is_v6 := tt.endpoint.address.(net.IP6_Address)
	family: posix.AF = .INET6 if is_v6 else .INET

	fd := posix.socket(family, .STREAM, .IP)
	if fd == -1 {
		return 0, .Connect_Failed
	}
	if !_posix_set_nonblocking(fd) {
		posix.close(fd)
		return 0, .Connect_Failed
	}

	res: posix.result
	addr_len: posix.socklen_t
	when ODIN_OS == .Linux {
		if v4, ok := tt.endpoint.address.(net.IP4_Address); ok {
			addr: posix.sockaddr_in
			addr.sin_family = .INET
			addr.sin_port = u16be(u16(tt.endpoint.port))
			addr.sin_addr.s_addr = transmute(u32be)v4
			res = posix.connect(fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr)))
		} else if v6, ok6 := tt.endpoint.address.(net.IP6_Address); ok6 {
			addr: posix.sockaddr_in6
			addr.sin6_family = .INET6
			addr.sin6_port = u16be(u16(tt.endpoint.port))
			addr.sin6_addr.s6_addr = transmute([16]u8)v6
			res = posix.connect(fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr)))
		}
		addr_len = 0
	} else {
		if v4, ok := tt.endpoint.address.(net.IP4_Address); ok {
			addr: posix.sockaddr_in
			addr.sin_len = u8(size_of(posix.sockaddr_in))
			addr.sin_family = .INET
			addr.sin_port = u16be(u16(tt.endpoint.port))
			addr.sin_addr.s_addr = transmute(u32be)v4
			res = posix.connect(fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr)))
		} else if v6, ok6 := tt.endpoint.address.(net.IP6_Address); ok6 {
			addr: posix.sockaddr_in6
			addr.sin6_len = u8(size_of(posix.sockaddr_in6))
			addr.sin6_family = .INET6
			addr.sin6_port = u16be(u16(tt.endpoint.port))
			addr.sin6_addr.s6_addr = transmute([16]u8)v6
			res = posix.connect(fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr)))
		}
		addr_len = 0
	}
	_ = addr_len

	if res == .OK {
		return fd, .None // completed immediately
	}
	if posix.errno() != .EINPROGRESS {
		posix.close(fd)
		return 0, .Connect_Failed
	}
	if ferr := _transport_finish_connect(fd, deadline); ferr != .None {
		posix.close(fd)
		return 0, ferr
	}
	return fd, .None
}

_tcp_close :: proc(data: rawptr, fd: posix.FD) {
	_transport_close_fd(fd)
	free(cast(^_TCP_Transport)data)
}
