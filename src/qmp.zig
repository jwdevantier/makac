// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// qmp.zig — a synchronous, single-threaded QEMU Management Protocol client.
//
// Core model:
//   * A `Client` carries one connection: the socket fd (via a `Transport`),
//     the circular read buffer, the buffered-event queue, and an allocator
//     that owns all client-managed memory.
//   * `send` clears the event buffer (when asked), writes one command line,
//     then reads until that command's JSON reply arrives or the deadline is
//     hit. Events seen while waiting are buffered.
//   * `poll` reads whatever is currently available (bounded by a timeout),
//     appending events to the queue, and reports whether it drained any. A
//     poll timeout is NOT an error.
//   * `consume` discards the n oldest buffered events.
//   * Every read/write drains with a deadline, so a hung QEMU never blocks
//     the caller forever. No busy-spin loops.
//
// JSON parsing/serialization is reused from vm/json.zig, so integral numbers
// stay Lua integers in both directions.

const std = @import("std");
const linux = std.os.linux;
const json = @import("vm/json.zig");
const JsonValue = json.Value;

pub const READ_BUF_CAP: usize = 256 * 1024;

/// Runtime error codes for the client. `.none` means success.
pub const Error = enum {
    none,
    connect_failed,
    not_connected,
    timeout,
    protocol_error,
    connection_lost,
    write_failed,
    out_of_memory,
};

pub fn errorString(e: Error) []const u8 {
    return switch (e) {
        .none => "no error",
        .connect_failed => "connect/handshake failed",
        .not_connected => "not connected",
        .timeout => "timed out (VM unresponsive)",
        .protocol_error => "protocol error",
        .connection_lost => "connection lost",
        .write_failed => "write failed",
        .out_of_memory => "out of memory",
    };
}

/// Structured details about a command rejected by QEMU (`{"error":...}`).
pub const QmpError = struct {
    class: []u8 = &.{},
    desc: []u8 = &.{},
};

/// A single asynchronous event delivered by QEMU. `payload` is the full
/// parsed event object, deep-cloned into the client's allocator.
pub const Event = struct {
    name: []u8,
    payload: JsonValue,
};

/// The result of one `send` command. Either `ok` and `return_json` are set,
/// or `ok == false` and `err` describes the QEMU-level rejection.
pub const Reply = struct {
    ok: bool = false,
    complete: bool = false,
    return_json: JsonValue = .nil,
    err: QmpError = .{},
};

pub const SendOutcome = struct {
    reply: Reply = .{},
    err: Error = .none,
};

pub const PollOutcome = struct {
    drained: bool = false,
    err: Error = .none,
};

pub const ConnectOutcome = struct {
    client: ?Client = null,
    err: Error = .none,
};

// ------------------------------------------------------------- time --------

fn nowNanos() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn deadlineFrom(timeout_ns: i128) i128 {
    if (timeout_ns <= 0) return nowNanos();
    return nowNanos() + timeout_ns;
}

fn remaining(deadline: i128) i128 {
    const d = deadline - nowNanos();
    return if (d > 0) d else 0;
}

fn expired(deadline: i128) bool {
    return nowNanos() > deadline;
}

fn msUntil(deadline: i128) i32 {
    const d = deadline - nowNanos();
    if (d <= 0) return 0;
    const ms = @divTrunc(d, std.time.ns_per_ms);
    if (ms > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(ms);
}

// -------------------------------------------------------- transport -------

const TransportKind = enum { unix, tcp };

/// One connection backend. The fd is recorded on success; `closeTransport`
/// releases it (and is idempotent).
const Transport = struct {
    kind: TransportKind,
    fd: linux.fd_t = -1,
    path: [108]u8 = undefined,
    path_len: usize = 0,
    has_v6: bool = false,
    ip4: [4]u8 = undefined,
    ip6: [16]u8 = undefined,
    port: u16 = 0,

    fn buildUnix(path: []const u8) ?Transport {
        // Linux allows 108 bytes including the terminating NUL.
        if (path.len == 0 or path.len >= 108) return null;
        var t = Transport{ .kind = .unix, .path_len = path.len };
        @memcpy(t.path[0..path.len], path);
        return t;
    }

    fn buildTcp(endpoint: []const u8) ?Transport {
        const parsed = parseEndpoint(endpoint) orelse return null;
        const ip = std.Io.net.IpAddress.parse(parsed.host, parsed.port) catch return null;
        var t = Transport{ .kind = .tcp };
        switch (ip) {
            .ip4 => |a| {
                t.ip4 = a.bytes;
                t.port = a.port;
            },
            .ip6 => |a| {
                t.has_v6 = true;
                t.ip6 = a.bytes;
                t.port = a.port;
            },
        }
        return t;
    }

    fn connect(self: *Transport, deadline: i128) Error {
        return switch (self.kind) {
            .unix => self.connectUnix(deadline),
            .tcp => self.connectTcp(deadline),
        };
    }

    fn connectUnix(self: *Transport, deadline: i128) Error {
        self.fd = -1;
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0);
        if (linux.errno(rc) != .SUCCESS) return .connect_failed;
        const fd: linux.fd_t = @intCast(rc);

        var addr: linux.sockaddr.un = std.mem.zeroes(linux.sockaddr.un);
        addr.family = linux.AF.UNIX;
        @memcpy(addr.path[0..self.path_len], self.path[0..self.path_len]);
        const crc = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
        const e = linux.errno(crc);
        if (e == .INPROGRESS) {
            const ferr = finishConnect(fd, deadline);
            if (ferr != .none) {
                _ = linux.close(fd);
                return ferr;
            }
        } else if (e != .SUCCESS) {
            _ = linux.close(fd);
            return .connect_failed;
        }
        self.fd = fd;
        return .none;
    }

    fn connectTcp(self: *Transport, deadline: i128) Error {
        self.fd = -1;
        const family: u32 = if (self.has_v6) @intCast(linux.AF.INET6) else @intCast(linux.AF.INET);
        const rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0);
        if (linux.errno(rc) != .SUCCESS) return .connect_failed;
        const fd: linux.fd_t = @intCast(rc);

        var crc: usize = undefined;
        if (self.has_v6) {
            var addr: linux.sockaddr.in6 = std.mem.zeroes(linux.sockaddr.in6);
            addr.family = linux.AF.INET6;
            addr.port = std.mem.nativeToBig(u16, self.port);
            addr.addr = self.ip6;
            crc = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in6));
        } else {
            var addr: linux.sockaddr.in = std.mem.zeroes(linux.sockaddr.in);
            addr.family = linux.AF.INET;
            addr.port = std.mem.nativeToBig(u16, self.port);
            addr.addr = @bitCast(self.ip4);
            crc = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
        }
        const e = linux.errno(crc);
        if (e == .INPROGRESS) {
            const ferr = finishConnect(fd, deadline);
            if (ferr != .none) {
                _ = linux.close(fd);
                return ferr;
            }
        } else if (e != .SUCCESS) {
            _ = linux.close(fd);
            return .connect_failed;
        }
        self.fd = fd;
        return .none;
    }

    fn closeTransport(self: *Transport) void {
        if (self.fd != -1) {
            _ = linux.shutdown(self.fd, linux.SHUT.RDWR);
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }
};

const ParsedEndpoint = struct { host: []const u8, port: u16 };

fn parseEndpoint(endpoint: []const u8) ?ParsedEndpoint {
    if (endpoint.len == 0) return null;
    var host: []const u8 = undefined;
    var port_s: []const u8 = undefined;
    if (endpoint[0] == '[') {
        const rbracket = std.mem.indexOfScalar(u8, endpoint, ']') orelse return null;
        host = endpoint[1..rbracket];
        if (rbracket + 1 >= endpoint.len or endpoint[rbracket + 1] != ':') return null;
        port_s = endpoint[rbracket + 2 ..];
    } else {
        const colon = std.mem.lastIndexOfScalar(u8, endpoint, ':') orelse return null;
        host = endpoint[0..colon];
        port_s = endpoint[colon + 1 ..];
    }
    if (host.len == 0) return null;
    const port = std.fmt.parseInt(u16, port_s, 10) catch return null;
    if (port == 0) return null;
    return .{ .host = host, .port = port };
}

/// Complete a non-blocking connect: wait for writability up to `deadline`,
/// then verify via SO_ERROR (the only reliable way to learn the result).
fn finishConnect(fd: linux.fd_t, deadline: i128) Error {
    while (true) {
        var pfd = linux.pollfd{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 };
        const n = linux.poll(@ptrCast(&pfd), 1, msUntil(deadline));
        const e = linux.errno(n);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return .connect_failed;
        if (n == 0) return .timeout;
        var serr: i32 = 0;
        var slen: linux.socklen_t = @sizeOf(i32);
        const grc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&serr), &slen);
        if (linux.errno(grc) != .SUCCESS or serr != 0) return .connect_failed;
        return .none;
    }
}

// -------------------------------------------------------------- client -----

/// The client is caller-owned (by value / inline in the Lua userdata).
/// `close` frees its internals but not the struct itself.
pub const Client = struct {
    transport: Transport,
    connected: bool,
    rbuf: []u8,
    rstart: usize,
    rlen: usize,
    events: std.ArrayList(Event),
    allocator: std.mem.Allocator,
    scratch: std.heap.ArenaAllocator,
    last_reply: Reply,
};

fn initClient(t: Transport, allocator: std.mem.Allocator) ?Client {
    const rbuf = allocator.alloc(u8, READ_BUF_CAP) catch return null;
    return .{
        .transport = t,
        .connected = false,
        .rbuf = rbuf,
        .rstart = 0,
        .rlen = 0,
        .events = .empty,
        .allocator = allocator,
        .scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator),
        .last_reply = .{},
    };
}

fn deinitClient(c: *Client) void {
    const allocator = c.allocator;
    clearEvents(c);
    clearReply(c, &c.last_reply);
    c.events.deinit(allocator);
    c.scratch.deinit();
    allocator.free(c.rbuf);
    c.transport.closeTransport();
    c.connected = false;
}

/// Connect over a unix socket, perform the greeting + `qmp_capabilities`
/// handshake, and return a ready client. `timeout_ns` bounds the whole
/// connect+handshake.
pub fn connectUnix(
    path: []const u8,
    timeout_ns: i128,
    allocator: std.mem.Allocator,
) ConnectOutcome {
    const t = Transport.buildUnix(path) orelse return .{ .err = .connect_failed };
    return connectTransport(t, timeout_ns, allocator);
}

/// Connect to a `"host:port"` QMP endpoint (IPv4 or IPv6).
pub fn connectTcp(
    endpoint: []const u8,
    timeout_ns: i128,
    allocator: std.mem.Allocator,
) ConnectOutcome {
    const t = Transport.buildTcp(endpoint) orelse return .{ .err = .connect_failed };
    return connectTransport(t, timeout_ns, allocator);
}

fn connectTransport(t: Transport, timeout_ns: i128, allocator: std.mem.Allocator) ConnectOutcome {
    var c = initClient(t, allocator) orelse return .{ .err = .out_of_memory };
    const deadline = deadlineFrom(timeout_ns);

    const cerr = c.transport.connect(deadline);
    if (cerr != .none) {
        deinitClient(&c);
        return .{ .err = cerr };
    }
    c.connected = true;

    // 1. Read the QMP greeting; it is neither a reply nor an event.
    const gerr = readGreeting(&c, deadline);
    if (gerr != .none) {
        deinitClient(&c);
        return .{ .err = gerr };
    }

    // 2. Negotiate capabilities.
    const outcome = send(&c, "{\"execute\":\"qmp_capabilities\"}", remaining(deadline), true);
    if (outcome.err != .none) {
        deinitClient(&c);
        return .{ .err = outcome.err };
    }
    if (!outcome.reply.ok) {
        deinitClient(&c);
        return .{ .err = .protocol_error };
    }
    return .{ .client = c };
}

pub fn connected(c: *Client) bool {
    return c.connected;
}

pub fn close(c: *Client) void {
    deinitClient(c);
}

// -------------------------------------------------- memory ownership -------

/// Allocation failures during JSON cloning are surfaced as `.out_of_memory`
/// by the callers below.
const AllocError = error{OutOfMemory};

fn cloneValue(alloc: std.mem.Allocator, v: JsonValue) AllocError!JsonValue {
    return switch (v) {
        .nil => .nil,
        .boolean => |b| .{ .boolean = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = try alloc.dupe(u8, s) },
        .array => |a| blk: {
            const out = try alloc.alloc(JsonValue, a.len);
            for (a, 0..) |e, i| out[i] = try cloneValue(alloc, e);
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            const out = try alloc.alloc(json.Entry, o.len);
            for (o, 0..) |e, i| {
                const key = try alloc.dupe(u8, e.key);
                out[i] = .{ .key = key, .value = try cloneValue(alloc, e.value) };
            }
            break :blk .{ .object = out };
        },
    };
}

fn freeValue(alloc: std.mem.Allocator, v: JsonValue) void {
    switch (v) {
        .string => |s| alloc.free(s),
        .array => |a| {
            for (a) |e| freeValue(alloc, e);
            alloc.free(a);
        },
        .object => |o| {
            for (o) |e| {
                alloc.free(e.key);
                freeValue(alloc, e.value);
            }
            alloc.free(o);
        },
        else => {},
    }
}

fn clearEvents(c: *Client) void {
    for (c.events.items) |ev| {
        c.allocator.free(ev.name);
        freeValue(c.allocator, ev.payload);
    }
    c.events.clearRetainingCapacity();
}

fn clearReply(c: *Client, r: *Reply) void {
    freeValue(c.allocator, r.return_json);
    c.allocator.free(r.err.class);
    c.allocator.free(r.err.desc);
    r.* = .{};
}

fn pushEvent(c: *Client, name: []const u8, payload: JsonValue) AllocError!void {
    const n = try c.allocator.dupe(u8, name);
    errdefer c.allocator.free(n);
    const p = try cloneValue(c.allocator, payload);
    c.events.append(c.allocator, .{ .name = n, .payload = p }) catch return error.OutOfMemory;
}

// ------------------------------------------------------- wire framing ------

fn waitReadable(c: *Client, timeout_ms: i32) Error {
    while (true) {
        var pfd = linux.pollfd{ .fd = c.transport.fd, .events = @intCast(linux.POLL.IN), .revents = 0 };
        const n = linux.poll(@ptrCast(&pfd), 1, if (timeout_ms < 0) 0 else timeout_ms);
        const e = linux.errno(n);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return .connection_lost;
        if (n == 0) return .timeout;
        const bad: i16 = @intCast(linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL);
        if ((pfd.revents & bad) != 0 and (pfd.revents & @as(i16, @intCast(linux.POLL.IN))) == 0) {
            return .connection_lost;
        }
        return .none;
    }
}

fn writeAll(c: *Client, b: []const u8, deadline: i128) Error {
    var off: usize = 0;
    while (off < b.len) {
        const rc = linux.write(c.transport.fd, b.ptr + off, b.len - off);
        const e = linux.errno(rc);
        if (e == .SUCCESS) {
            if (rc == 0) return .write_failed;
            off += rc;
            continue;
        }
        if (e == .AGAIN) {
            const rem = msUntil(deadline);
            if (rem <= 0) return .timeout;
            var pfd = linux.pollfd{ .fd = c.transport.fd, .events = @intCast(linux.POLL.OUT), .revents = 0 };
            if (linux.errno(linux.poll(@ptrCast(&pfd), 1, rem)) != .SUCCESS) return .write_failed;
            continue;
        }
        return .write_failed;
    }
    return .none;
}

/// Copy bytes into the circular read buffer, compacting first if needed.
fn bufferBytes(c: *Client, data: []const u8) Error {
    if (c.rlen + data.len > c.rbuf.len) {
        std.mem.copyForwards(u8, c.rbuf[0..c.rlen], c.rbuf[c.rstart .. c.rstart + c.rlen]);
        c.rstart = 0;
    }
    if (c.rlen + data.len > c.rbuf.len) return .protocol_error;
    std.mem.copyForwards(
        u8,
        c.rbuf[c.rstart + c.rlen .. c.rstart + c.rlen + data.len],
        data,
    );
    c.rlen += data.len;
    return .none;
}

/// Pop the next complete '\n'-terminated line. Returns null when no full,
/// non-blank line is buffered (blank lines are consumed and skipped).
fn nextLine(c: *Client) ?[]const u8 {
    const window = c.rbuf[c.rstart .. c.rstart + c.rlen];
    const idx = std.mem.indexOfScalar(u8, window, '\n') orelse return null;
    const raw = window[0..idx];
    const line = std.mem.trim(u8, raw, " \t\r\n\x0b\x0c");
    c.rstart += idx + 1;
    c.rlen -= idx + 1;
    if (c.rlen == 0) c.rstart = 0;
    if (line.len == 0) return null;
    return line;
}

fn drain(c: *Client, deadline: i128, reply: *Reply, want_reply: bool) Error {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const werr = waitReadable(c, msUntil(deadline));
        if (werr != .none) return werr;

        while (true) {
            const rc = linux.read(c.transport.fd, &buf, buf.len);
            const e = linux.errno(rc);
            if (e == .AGAIN) break;
            if (e != .SUCCESS or rc == 0) {
                c.connected = false;
                return .connection_lost;
            }
            const berr = bufferBytes(c, buf[0..rc]);
            if (berr != .none) return berr;

            while (nextLine(c)) |line| {
                const derr = dispatchLine(c, line, reply);
                if (derr != .none) return derr;
                if (want_reply and reply.complete) return .none;
            }
        }

        if (want_reply and reply.complete) return .none;
        if (!want_reply and expired(deadline)) return .timeout;
    }
}

/// Read raw bytes until the QMP greeting line arrives, then consume it.
fn readGreeting(c: *Client, deadline: i128) Error {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        if (nextLine(c) != null) return .none;
        const werr = waitReadable(c, msUntil(deadline));
        if (werr != .none) return werr;
        const rc = linux.read(c.transport.fd, &buf, buf.len);
        const e = linux.errno(rc);
        if (e == .AGAIN) continue;
        if (e != .SUCCESS or rc == 0) {
            c.connected = false;
            return .connection_lost;
        }
        const berr = bufferBytes(c, buf[0..rc]);
        if (berr != .none) return berr;
    }
}

fn findKey(entries: []const json.Entry, key: []const u8) ?JsonValue {
    for (entries) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.value;
    }
    return null;
}

/// Inspect one JSON line: buffer events, fill `reply` on command replies.
fn dispatchLine(c: *Client, line: []const u8, reply: *Reply) Error {
    const scratch = c.scratch.allocator();
    const value = json.parseJson(line, scratch) catch return .none; // ignore noise
    const entries = switch (value) {
        .object => |o| o,
        else => return .none,
    };

    if (findKey(entries, "event")) |ev| {
        if (ev == .string) pushEvent(c, ev.string, value) catch return .out_of_memory;
        return .none;
    }
    if (findKey(entries, "return")) |ret| {
        reply.ok = true;
        reply.complete = true;
        reply.return_json = cloneValue(c.allocator, ret) catch return .out_of_memory;
        return .none;
    }
    if (findKey(entries, "error")) |e| {
        if (e == .object) {
            const eo = e.object;
            if (findKey(eo, "class")) |cls| {
                if (cls == .string) reply.err.class = c.allocator.dupe(u8, cls.string) catch return .out_of_memory;
            }
            if (findKey(eo, "desc")) |dsc| {
                if (dsc == .string) reply.err.desc = c.allocator.dupe(u8, dsc.string) catch return .out_of_memory;
            }
        }
        reply.complete = true;
        return .none;
    }
    return .none;
}

// ---------------------------------------------------------- public API -----

/// Send a QMP command line and synchronously await its reply.
///
/// When `clear_events` is true the event buffer is emptied first; events that
/// arrive while waiting are buffered. Pass false to APPEND (the Lua binding
/// does this for commands after the first in a batch).
pub fn send(c: *Client, command: []const u8, timeout_ns: i128, clear_events: bool) SendOutcome {
    if (!c.connected) return .{ .err = .not_connected };
    if (clear_events) clearEvents(c);
    clearReply(c, &c.last_reply);
    _ = c.scratch.reset(.retain_capacity);

    const deadline = deadlineFrom(timeout_ns);

    // Write the command line (the arena owns the transient buffer).
    const arena = c.scratch.allocator();
    const buf = arena.alloc(u8, command.len + 1) catch return .{ .err = .out_of_memory };
    @memcpy(buf[0..command.len], command);
    buf[command.len] = '\n';
    const werr = writeAll(c, buf, deadline);
    if (werr != .none) return .{ .err = werr };

    var reply = Reply{};
    const derr = drain(c, deadline, &reply, true);
    if (derr != .none) {
        clearReply(c, &reply);
        if (derr == .timeout) return .{ .err = .timeout };
        return .{ .err = derr };
    }
    c.last_reply = reply;
    return .{ .reply = reply, .err = .none };
}

/// Read any currently available QMP messages, buffering events. A timeout is
/// not an error. Returns whether any events were drained during this call.
pub fn poll(c: *Client, timeout_ns: i128) PollOutcome {
    if (!c.connected) return .{ .err = .not_connected };
    _ = c.scratch.reset(.retain_capacity);
    const start = c.events.items.len;
    const deadline = deadlineFrom(timeout_ns);
    var discard = Reply{};
    const derr = drain(c, deadline, &discard, false);
    clearReply(c, &discard);
    const err: Error = if (derr == .timeout) .none else derr;
    return .{ .drained = c.events.items.len > start, .err = err };
}

/// Drop the `n` oldest buffered events (clamped to the buffered count).
pub fn consume(c: *Client, n: usize) void {
    const count = @min(n, c.events.items.len);
    if (count == 0) return;
    for (c.events.items[0..count]) |ev| {
        c.allocator.free(ev.name);
        freeValue(c.allocator, ev.payload);
    }
    const rest = c.events.items.len - count;
    std.mem.copyForwards(Event, c.events.items[0..rest], c.events.items[count..]);
    c.events.shrinkRetainingCapacity(rest);
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

// Scripted in-process QMP server (unix + tcp). One connection, line JSON,
// responses keyed by command.
const greeting =
    "{\"QMP\":{\"version\":{\"qemu\":{\"major\":8,\"minor\":0,\"micro\":0}," ++
    "\"package\":\"fake\"},\"capabilities\":[]}}\n";

const FakeServer = struct {
    ln: linux.fd_t,
    thread: std.Thread,
    unix_path: ?[:0]u8 = null,
    tcp_endpoint: [64]u8 = undefined,
    tcp_len: usize = 0,
    split_greeting: bool = false,
};

var fake_counter: u32 = 0;

fn ignoreSigpipe() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &act, null);
}

fn writeRaw(fd: linux.fd_t, s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const n = linux.write(fd, s.ptr + off, s.len - off);
        if (linux.errno(n) != .SUCCESS) return;
        off += n;
    }
}

fn sleepMs(ms: i64) void {
    var ts = linux.timespec{ .sec = @divTrunc(ms, 1000), .nsec = @mod(ms, 1000) * std.time.ns_per_ms };
    _ = linux.nanosleep(&ts, null);
}

fn respond(fd: linux.fd_t, cmd: []const u8) void {
    if (std.mem.indexOf(u8, cmd, "qmp_capabilities") != null) {
        writeRaw(fd, "{\"return\":{}}\n");
    } else if (std.mem.indexOf(u8, cmd, "query-status") != null) {
        writeRaw(fd, "{\"event\":\"RTC_CHANGE\",\"data\":{\"offset\":1},\"timestamp\":{\"seconds\":1,\"microseconds\":2}}\n");
        writeRaw(fd, "{\"event\":\"SPICE_INITIALIZED\",\"data\":{}}\n");
        writeRaw(fd, "{\"return\":{\"status\":\"running\",\"running\":true}}\n");
    } else if (std.mem.indexOf(u8, cmd, "query-block") != null) {
        writeRaw(fd, "{\"event\":\"BLOCK_IO_ERROR\",\"data\":{\"device\":\"drive0\"}}\n");
        writeRaw(fd, "{\"return\":[{\"device\":\"drive0\",\"type\":\"unknown\"}]}\n");
    } else if (std.mem.indexOf(u8, cmd, "bad-cmd") != null) {
        writeRaw(fd, "{\"error\":{\"class\":\"CommandNotFound\",\"desc\":\"The command bad-cmd has not been found\"}}\n");
    } else if (std.mem.indexOf(u8, cmd, "emit-later") != null) {
        writeRaw(fd, "{\"return\":{}}\n");
        sleepMs(60);
        writeRaw(fd, "{\"event\":\"RESET\",\"data\":{\"guest\":true},\"timestamp\":{\"seconds\":3,\"microseconds\":4}}\n");
        writeRaw(fd, "{\"event\":\"SHUTDOWN\",\"data\":{\"guest\":false}}\n");
    } else if (std.mem.indexOf(u8, cmd, "hang") != null) {
        // never reply (exercises the send deadline)
    } else {
        writeRaw(fd, "{\"return\":{}}\n");
    }
}

fn serve(srv: *FakeServer) void {
    const conn = linux.accept(srv.ln, null, null);
    if (linux.errno(conn) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(conn);
    defer _ = linux.close(fd);

    if (srv.split_greeting) {
        writeRaw(fd, greeting[0..7]);
        sleepMs(10);
        writeRaw(fd, greeting[7..]);
    } else {
        writeRaw(fd, greeting);
    }

    var buf: [64 * 1024]u8 = undefined;
    var pending: usize = 0;
    while (true) {
        const n = linux.read(fd, buf[pending..].ptr, buf.len - pending);
        const e = linux.errno(n);
        if (e != .SUCCESS or n == 0) break;
        pending += n;
        while (std.mem.indexOfScalar(u8, buf[0..pending], '\n')) |idx| {
            respond(fd, buf[0..idx]);
            const rest = pending - (idx + 1);
            std.mem.copyForwards(u8, buf[0..rest], buf[idx + 1 .. pending]);
            pending = rest;
        }
    }
}

fn listenUnix(path: [:0]const u8) !linux.fd_t {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Socket;
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    var addr: linux.sockaddr.un = std.mem.zeroes(linux.sockaddr.un);
    addr.family = linux.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.Bind;
    if (linux.errno(linux.listen(fd, 1)) != .SUCCESS) return error.Listen;
    return fd;
}

fn startUnix(alloc: std.mem.Allocator, split_greeting: bool) !*FakeServer {
    ignoreSigpipe();
    const srv = try alloc.create(FakeServer);
    errdefer alloc.destroy(srv);
    const raw_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/makac_qmp_{d}_{d}.sock",
        .{ linux.getpid(), fake_counter },
    );
    defer alloc.free(raw_path);
    const path = try alloc.dupeZ(u8, raw_path);
    fake_counter += 1;
    srv.* = .{ .ln = try listenUnix(path), .thread = undefined, .split_greeting = split_greeting };
    srv.unix_path = path;
    srv.thread = try std.Thread.spawn(.{}, serve, .{srv});
    return srv;
}

fn startTcp(alloc: std.mem.Allocator) !*FakeServer {
    ignoreSigpipe();
    const srv = try alloc.create(FakeServer);
    errdefer alloc.destroy(srv);

    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Socket;
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);

    var addr: linux.sockaddr.in = std.mem.zeroes(linux.sockaddr.in);
    addr.family = linux.AF.INET;
    addr.port = 0;
    addr.addr = @bitCast([4]u8{ 127, 0, 0, 1 });
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.Bind;
    if (linux.errno(linux.listen(fd, 1)) != .SUCCESS) return error.Listen;

    var bound: linux.sockaddr.in = std.mem.zeroes(linux.sockaddr.in);
    var blen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&bound), &blen)) != .SUCCESS) return error.Socket;
    const ep = try std.fmt.bufPrint(&srv.tcp_endpoint, "127.0.0.1:{d}", .{std.mem.bigToNative(u16, bound.port)});
    srv.* = .{ .ln = fd, .thread = undefined, .tcp_len = ep.len };
    srv.thread = try std.Thread.spawn(.{}, serve, .{srv});
    return srv;
}

fn stop(srv: *FakeServer, alloc: std.mem.Allocator) void {
    _ = linux.shutdown(srv.ln, linux.SHUT.RDWR);
    srv.thread.join();
    _ = linux.close(srv.ln);
    if (srv.unix_path) |p| {
        _ = linux.unlink(p.ptr);
        alloc.free(p);
    }
    alloc.destroy(srv);
}

fn connectTo(srv: *FakeServer, alloc: std.mem.Allocator) ConnectOutcome {
    if (srv.unix_path) |p| return connectUnix(p, 5 * std.time.ns_per_s, alloc);
    return connectTcp(srv.tcp_endpoint[0..srv.tcp_len], 5 * std.time.ns_per_s, alloc);
}

fn activeTag(v: JsonValue) std.meta.Tag(JsonValue) {
    return std.meta.activeTag(v);
}

test "handshake + greeting; reply decoded with integer preservation" {
    const alloc = testing.allocator;
    const srv = try startUnix(alloc, false);
    defer stop(srv, alloc);

    const out = connectTo(srv, alloc);
    try testing.expectEqual(Error.none, out.err);
    var client = out.client.?;
    defer close(&client);
    try testing.expect(connected(&client));

    const res = send(&client, "{\"execute\":\"query-status\"}", 5 * std.time.ns_per_s, true);
    try testing.expectEqual(Error.none, res.err);
    try testing.expect(res.reply.ok);
    try testing.expectEqual(@as(usize, 2), client.events.items.len);
    try testing.expectEqualStrings("RTC_CHANGE", client.events.items[0].name);
    try testing.expectEqualStrings("SPICE_INITIALIZED", client.events.items[1].name);

    const data = findKey(client.events.items[0].payload.object, "data").?;
    const offset = findKey(data.object, "offset").?;
    try testing.expectEqual(std.meta.Tag(JsonValue).integer, activeTag(offset));
    try testing.expectEqual(@as(i64, 1), offset.integer);
    const ts = findKey(client.events.items[0].payload.object, "timestamp").?;
    const seconds = findKey(ts.object, "seconds").?;
    try testing.expectEqual(std.meta.Tag(JsonValue).integer, activeTag(seconds));
}

test "line framing survives a greeting split across reads" {
    const alloc = testing.allocator;
    const srv = try startUnix(alloc, true);
    defer stop(srv, alloc);

    const out = connectTo(srv, alloc);
    try testing.expectEqual(Error.none, out.err);
    var client = out.client.?;
    defer close(&client);

    const res = send(&client, "{\"execute\":\"query-block\"}", 5 * std.time.ns_per_s, true);
    try testing.expectEqual(Error.none, res.err);
    try testing.expect(res.reply.ok);
    try testing.expectEqual(std.meta.Tag(JsonValue).array, activeTag(res.reply.return_json));
    try testing.expectEqualStrings("drive0", res.reply.return_json.array[0].object[0].value.string);
}

test "batched commands: results align by position; QMP error is data" {
    const alloc = testing.allocator;
    const srv = try startUnix(alloc, false);
    defer stop(srv, alloc);

    const out = connectTo(srv, alloc);
    try testing.expectEqual(Error.none, out.err);
    var client = out.client.?;
    defer close(&client);

    // first command clears; second appends -> BLOCK_IO_ERROR survives
    const a = send(&client, "{\"execute\":\"query-block\"}", 5 * std.time.ns_per_s, true);
    try testing.expectEqual(Error.none, a.err);
    const b = send(&client, "{\"execute\":\"anything\",\"arguments\":{\"id\":\"x\",\"n\":3}}", 5 * std.time.ns_per_s, false);
    try testing.expectEqual(Error.none, b.err);
    try testing.expect(b.reply.ok);
    try testing.expectEqual(@as(usize, 1), client.events.items.len);
    try testing.expectEqualStrings("BLOCK_IO_ERROR", client.events.items[0].name);

    const bad = send(&client, "{\"execute\":\"bad-cmd\"}", 5 * std.time.ns_per_s, true);
    try testing.expectEqual(Error.none, bad.err);
    try testing.expect(!bad.reply.ok);
    try testing.expect(bad.reply.complete);
    try testing.expectEqualStrings("CommandNotFound", bad.reply.err.class);
    try testing.expect(std.mem.indexOf(u8, bad.reply.err.desc, "bad-cmd") != null);
}

test "event discipline: poll, events(n) does not consume, consume drops oldest" {
    const alloc = testing.allocator;
    const srv = try startUnix(alloc, false);
    defer stop(srv, alloc);

    const out = connectTo(srv, alloc);
    try testing.expectEqual(Error.none, out.err);
    var client = out.client.?;
    defer close(&client);

    // emit-later replies immediately, then pushes two events after a delay
    const res = send(&client, "{\"execute\":\"emit-later\"}", 5 * std.time.ns_per_s, true);
    try testing.expectEqual(Error.none, res.err);

    const idle = poll(&client, 0);
    try testing.expectEqual(Error.none, idle.err);
    try testing.expect(!idle.drained);

    const drained = poll(&client, 400 * std.time.ns_per_ms);
    try testing.expectEqual(Error.none, drained.err);
    try testing.expect(drained.drained);
    try testing.expectEqual(@as(usize, 2), client.events.items.len);

    // events(n) reads without consuming (checked in the binding; here the
    // buffer is the source of truth)
    try testing.expectEqual(@as(usize, 2), client.events.items.len);
    consume(&client, 1);
    try testing.expectEqual(@as(usize, 1), client.events.items.len);
    try testing.expectEqualStrings("SHUTDOWN", client.events.items[0].name);
    consume(&client, 5); // clamped
    try testing.expectEqual(@as(usize, 0), client.events.items.len);
}

test "send deadline bounds an unresponsive command" {
    const alloc = testing.allocator;
    const srv = try startUnix(alloc, false);
    defer stop(srv, alloc);

    const out = connectTo(srv, alloc);
    try testing.expectEqual(Error.none, out.err);
    var client = out.client.?;
    defer close(&client);

    const start = nowNanos();
    const res = send(&client, "{\"execute\":\"hang\"}", 200 * std.time.ns_per_ms, true);
    const elapsed = nowNanos() - start;
    try testing.expectEqual(Error.timeout, res.err);
    try testing.expect(elapsed < 5 * std.time.ns_per_s);
}

test "close is safe, marks disconnected, and refuses further use" {
    const alloc = testing.allocator;
    const srv = try startUnix(alloc, false);
    defer stop(srv, alloc);

    const out = connectTo(srv, alloc);
    try testing.expectEqual(Error.none, out.err);
    var client = out.client.?;
    close(&client);
    try testing.expect(!connected(&client));
    const res = send(&client, "{\"execute\":\"query-status\"}", 5 * std.time.ns_per_s, true);
    try testing.expectEqual(Error.not_connected, res.err);
    const p = poll(&client, 0);
    try testing.expectEqual(Error.not_connected, p.err);
}

test "tcp transport seam: same client over a TCP endpoint" {
    const alloc = testing.allocator;
    const srv = try startTcp(alloc);
    defer stop(srv, alloc);

    const out = connectTo(srv, alloc);
    try testing.expectEqual(Error.none, out.err);
    var client = out.client.?;
    defer close(&client);

    const res = send(&client, "{\"execute\":\"query-block\"}", 5 * std.time.ns_per_s, true);
    try testing.expectEqual(Error.none, res.err);
    try testing.expect(res.reply.ok);
    try testing.expectEqualStrings("drive0", res.reply.return_json.array[0].object[0].value.string);
}

test "connect failure to a nonexistent unix socket is prompt" {
    const alloc = testing.allocator;
    const out = connectUnix("/tmp/makac_qmp_does_not_exist.sock", 500 * std.time.ns_per_ms, alloc);
    try testing.expect(out.err != .none);
    try testing.expect(out.client == null);
}
