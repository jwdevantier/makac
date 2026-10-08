// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// qmp.zig — the `makac.qmp_open` binding: an object-style Lua client over
// src/qmp.zig (design/qmp.md).
//
//   local q = makac.qmp_open("/run/vm/qmp.socket")          -- unix socket path
//   local q = makac.qmp_open({ tcp = "127.0.0.1:4444" })    -- tcp endpoint
//   local q = makac.qmp_open({ socket = path, timeout_s = 5 })
//
//   q:send(commands, { timeout_s = }?) -> results
//   q:poll({ timeout_s = }?) -> bool
//   q:events(n?) -> events
//   q:consume(n)
//   q:close()
//
// Lua writes and reads plain tables throughout; the JSON wire format is never
// part of the surface. Reply/event JSON is decoded by converters in vm/json.zig

const std = @import("std");
const lua = @import("../lua.zig");
const reg = @import("register.zig");
const json = @import("json.zig");
const qmp = @import("../qmp.zig");

const c_alloc = std.heap.c_allocator;

pub const MT: [:0]const u8 = "makac.qmp";

/// The userdata payload. `client` is owned by this object; `opened` guards
/// against double-close. `label` is the endpoint string (owned).
const QmpObject = struct {
    client: qmp.Client,
    label: []u8,
    opened: bool,
};

fn raiseFmt(L: *lua.State, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "makac.qmp: error";
    lua.raiseLString(L, msg);
}

fn checkQmpObject(L: *lua.State, arg: c_int) *QmpObject {
    const p = lua.checkUdata(L, arg, MT) orelse unreachable;
    return @ptrCast(@alignCast(p));
}

/// Type-checked self + open-client guard shared by the methods.
fn checkOpen(L: *lua.State, op: []const u8) *QmpObject {
    const self = checkQmpObject(L, 1);
    if (!self.opened) {
        raiseFmt(L, "makac.qmp: client is closed — {s} is no longer allowed", .{op});
    }
    return self;
}

/// Read an optional `timeout_s` (seconds, number) field from the opts table
/// at `idx`, defaulting to `def_ns`.
fn timeoutOpt(L: *lua.State, idx: c_int, def_ns: i128) i128 {
    if (lua.isNoneOrNil(L, idx)) return def_ns;
    lua.checkType(L, idx, lua.TTABLE);
    const t = lua.getField(L, idx, "timeout_s");
    defer lua.pop(L, 1);
    if (t == lua.TNIL) return def_ns;
    if (t != lua.TNUMBER) {
        lua.raise(L, "makac.qmp: opts.timeout_s must be a number (seconds)");
    }
    const secs = lua.toNumber(L, -1);
    if (secs < 0) {
        lua.raise(L, "makac.qmp: opts.timeout_s must not be negative");
    }
    return @intFromFloat(secs * 1e9);
}

// ------------------------------------------------------- metamethods -------

fn qmpIndex(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    _ = lua.checkUdata(L, 1, MT);
    if (lua.typeOf(L, 2) != lua.TSTRING) {
        lua.pushNil(L);
        return 1;
    }
    const key = lua.toLString(L, 2) orelse {
        lua.pushNil(L);
        return 1;
    };
    if (std.mem.eql(u8, key, "send")) {
        lua.pushCFunction(L, qmpSend);
    } else if (std.mem.eql(u8, key, "poll")) {
        lua.pushCFunction(L, qmpPoll);
    } else if (std.mem.eql(u8, key, "events")) {
        lua.pushCFunction(L, qmpEvents);
    } else if (std.mem.eql(u8, key, "consume")) {
        lua.pushCFunction(L, qmpConsume);
    } else if (std.mem.eql(u8, key, "close")) {
        lua.pushCFunction(L, qmpClose);
    } else {
        lua.pushNil(L);
    }
    return 1;
}

/// __gc: the leak backstop — never raises; safe work only (frees + fd close).
fn qmpGc(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const p = lua.toUserdata(L, 1) orelse return 0;
    const self: *QmpObject = @ptrCast(@alignCast(p));
    if (self.opened) {
        qmp.close(&self.client);
        self.opened = false;
    }
    c_alloc.free(self.label);
    self.label = &.{};
    return 0;
}

fn qmpTostring(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = checkQmpObject(L, 1);
    var buf: [512]u8 = undefined;
    const msg = if (self.opened)
        std.fmt.bufPrint(&buf, "makac.qmp: {s}", .{self.label}) catch "makac.qmp"
    else
        std.fmt.bufPrint(&buf, "makac.qmp: {s} (closed)", .{self.label}) catch "makac.qmp (closed)";
    lua.pushLString(L, msg);
    return 1;
}

// ---------------------------------------------------------- constructor ----

fn optStringField(L: *lua.State, idx: c_int, key: [:0]const u8) ?[]const u8 {
    const t = lua.getField(L, idx, key);
    defer lua.pop(L, 1);
    if (t == lua.TSTRING) return lua.toLString(L, -1);
    return null;
}

/// makac.qmp_open(spec) -> client userdata
fn makacQmpOpen(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;

    var socket_path: []const u8 = "";
    var tcp_endpoint: []const u8 = "";
    var timeout_ns: i128 = 5 * std.time.ns_per_s;

    const a1 = lua.typeOf(L, 1);
    if (a1 == lua.TSTRING) {
        socket_path = lua.toLString(L, 1) orelse "";
    } else if (!lua.isNoneOrNil(L, 1)) {
        lua.checkType(L, 1, lua.TTABLE);
        if (optStringField(L, 1, "socket")) |s| socket_path = s;
        if (optStringField(L, 1, "tcp")) |s| tcp_endpoint = s;
        if (socket_path.len != 0 and tcp_endpoint.len != 0) {
            lua.raise(L, "makac.qmp_open: give either spec.socket or spec.tcp, not both");
        }
        if (socket_path.len == 0 and tcp_endpoint.len == 0) {
            lua.raise(L, "makac.qmp_open: spec must set socket (unix path) or tcp (\"host:port\")");
        }
        timeout_ns = timeoutOpt(L, 1, timeout_ns);
    } else {
        lua.raise(L, "makac.qmp_open: a unix socket path (string) or a spec table is required");
    }

    var outcome: qmp.ConnectOutcome = undefined;
    if (tcp_endpoint.len != 0) {
        outcome = qmp.connectTcp(tcp_endpoint, timeout_ns, c_alloc);
    } else {
        outcome = qmp.connectUnix(socket_path, timeout_ns, c_alloc);
    }
    if (outcome.err != .none) {
        const label = if (tcp_endpoint.len != 0) tcp_endpoint else socket_path;
        raiseFmt(L, "makac.qmp_open: {s}: {s}", .{ label, qmp.errorString(outcome.err) });
    }
    const client = outcome.client.?;
    const label = if (tcp_endpoint.len != 0) tcp_endpoint else socket_path;

    const ud = lua.newUserdata(L, QmpObject);
    ud.* = .{
        .client = client,
        .label = c_alloc.dupe(u8, label) catch {
            qmp.close(&ud.client);
            lua.raise(L, "makac.qmp_open: out of memory");
        },
        .opened = true,
    };
    lua.setMetatable(L, MT);
    return 1;
}

// ------------------------------------------------------------- methods -----

/// qmp:send(commands, opts?) -> results array
fn qmpSend(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = checkOpen(L, "send");
    lua.checkType(L, 2, lua.TTABLE);
    const timeout_ns = timeoutOpt(L, 3, 5 * std.time.ns_per_s);

    const n = lua.rawLen(L, 2);
    if (n == 0) {
        lua.raise(L, "makac.qmp: send: commands must contain at least one command");
    }

    // Each command's JSON line is built in this arena, freed at the end.
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    lua.createTable(L, @intCast(n), 0); // results
    const results_idx = lua.absindex(L, -1);

    var i: usize = 1;
    while (i <= n) : (i += 1) {
        _ = lua.rawGetI(L, 2, @intCast(i)); // ... results cmd
        const cmd_idx = lua.absindex(L, -1);
        if (lua.typeOf(L, cmd_idx) != lua.TTABLE) {
            raiseFmt(L, "makac.qmp: send: commands[{d}] must be a table", .{i});
        }

        // execute (dup out of Lua before any further API call can GC it)
        if (lua.getField(L, cmd_idx, "execute") != lua.TSTRING) {
            raiseFmt(L, "makac.qmp: send: commands[{d}].execute must be a string", .{i});
        }
        const exe_lua = lua.toLString(L, -1) orelse unreachable;
        const exe = arena.dupe(u8, exe_lua) catch {
            lua.raise(L, "makac.qmp: send: out of memory");
        };
        lua.pop(L, 1); // execute

        // arguments?
        var args: ?json.Value = null;
        const at = lua.getField(L, cmd_idx, "arguments");
        if (at == lua.TTABLE) {
            var diag = json.Diag{};
            const path = std.fmt.allocPrint(arena, "commands[{d}].arguments", .{i}) catch {
                lua.raise(L, "makac.qmp: send: out of memory");
            };
            args = json.luaToJson(L, -1, path, "makac.qmp", 0, arena, &diag) catch {
                const msg = if (diag.msg.len != 0) diag.msg else "makac.qmp: send: cannot encode arguments";
                lua.raiseLString(L, msg);
            };
        } else if (at != lua.TNIL) {
            raiseFmt(L, "makac.qmp: send: commands[{d}].arguments must be a table", .{i});
        }
        lua.pop(L, 1); // arguments / nil
        lua.pop(L, 1); // command table

        // marshal {"execute":..., "arguments":...?}
        var entries: [2]json.Entry = undefined;
        entries[0] = .{ .key = "execute", .value = .{ .string = exe } };
        var nentries: usize = 1;
        if (args) |a| {
            entries[1] = .{ .key = "arguments", .value = a };
            nentries = 2;
        }
        const line = json.writeJson(arena, .{ .object = entries[0..nentries] }) catch {
            raiseFmt(L, "makac.qmp: send: commands[{d}]: failed to encode as JSON", .{i});
        };

        const outcome = qmp.send(&self.client, line, timeout_ns, i == 1);
        if (outcome.err != .none) {
            raiseFmt(
                L,
                "makac.qmp: send: commands[{d}] ({s}): {s}",
                .{ i, exe, qmp.errorString(outcome.err) },
            );
        }
        const reply = outcome.reply;

        // build the result entry
        lua.createTable(L, 0, 1); // ... results entry
        if (reply.ok) {
            var diag = json.Diag{};
            json.pushJson(L, reply.return_json, 0, &diag) catch {
                const msg = if (diag.msg.len != 0) diag.msg else "makac.qmp: send: cannot build reply";
                lua.raiseLString(L, msg);
            };
            lua.setField(L, -2, "return");
        } else {
            lua.createTable(L, 0, 2);
            lua.pushLString(L, reply.err.class);
            lua.setField(L, -2, "class");
            lua.pushLString(L, reply.err.desc);
            lua.setField(L, -2, "desc");
            lua.setField(L, -2, "error");
        }
        lua.rawSetI(L, results_idx, @intCast(i));
    }
    return 1;
}

/// qmp:poll(opts?) -> bool
fn qmpPoll(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = checkOpen(L, "poll");
    const timeout_ns = timeoutOpt(L, 2, 0);

    const outcome = qmp.poll(&self.client, timeout_ns);
    if (outcome.err != .none) {
        raiseFmt(L, "makac.qmp: poll: {s}: {s}", .{
            self.label,
            qmp.errorString(outcome.err),
        });
    }
    lua.pushBoolean(L, outcome.drained);
    return 1;
}

/// qmp:events(n?) -> events array (stays buffered)
fn qmpEvents(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = checkOpen(L, "events");

    const buffered = self.client.events.items.len;
    var n: usize = buffered;
    if (!lua.isNoneOrNil(L, 2)) {
        const raw = lua.checkInteger(L, 2);
        if (raw < 0) lua.raise(L, "makac.qmp: events: n must not be negative");
        n = @intCast(raw);
        if (n > buffered) {
            raiseFmt(L, "makac.qmp: events: cannot read {d} events, only {d} buffered", .{ n, buffered });
        }
    }

    lua.createTable(L, @intCast(n), 0);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ev = self.client.events.items[i];
        lua.createTable(L, 0, 3);
        lua.pushLString(L, ev.name);
        lua.setField(L, -2, "name");
        if (ev.payload == .object) {
            if (jsonEntry(ev.payload.object, "data")) |d| {
                pushJsonRaise(L, d);
                lua.setField(L, -2, "data");
            }
            if (jsonEntry(ev.payload.object, "timestamp")) |t| {
                pushJsonRaise(L, t);
                lua.setField(L, -2, "timestamp");
            }
        }
        lua.rawSetI(L, -2, @intCast(i + 1));
    }
    return 1;
}

/// qmp:consume(n)
fn qmpConsume(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = checkOpen(L, "consume");
    const raw = lua.checkInteger(L, 2);
    if (raw < 0) lua.raise(L, "makac.qmp: consume: n must not be negative");
    const n: usize = @intCast(raw);
    const buffered = self.client.events.items.len;
    if (n > buffered) {
        raiseFmt(L, "makac.qmp: consume: cannot consume {d} events, only {d} buffered", .{ n, buffered });
    }
    qmp.consume(&self.client, n);
    return 0;
}

/// qmp:close() — idempotent.
fn qmpClose(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = checkQmpObject(L, 1);
    if (self.opened) {
        qmp.close(&self.client);
        self.opened = false;
    }
    return 0;
}

// ------------------------------------------------------------- helpers -----

fn jsonEntry(entries: []const json.Entry, key: []const u8) ?json.Value {
    for (entries) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.value;
    }
    return null;
}

fn pushJsonRaise(L: *lua.State, v: json.Value) void {
    var diag = json.Diag{};
    json.pushJson(L, v, 0, &diag) catch {
        const msg = if (diag.msg.len != 0) diag.msg else "makac.qmp: cannot build value";
        lua.raiseLString(L, msg);
    };
}

// ---------------------------------------------------------- registration ---

/// Called while nothing in particular is on top; adds `makac.qmp_open` and
/// the `makac.qmp` metatable.
pub fn registerQmp(L: *lua.State) void {
    if (lua.newMetatable(L, MT)) {
        lua.pushCFunction(L, qmpIndex);
        lua.setField(L, -2, "__index");
        lua.pushCFunction(L, qmpGc);
        lua.setField(L, -2, "__gc");
        lua.pushCFunction(L, qmpTostring);
        lua.setField(L, -2, "__tostring");
    }
    lua.pop(L, 1); // the metatable

    reg.register(L, "qmp_open", makacQmpOpen);
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

test "qmp binding registers makac.qmp_open and the metatable" {
    const vm = try @import("../vm.zig").VM.new(testing.allocator, testing.io, .{});
    defer vm.deinit();
    try vm.runString(
        \\assert(type(makac.qmp_open) == "function", "qmp_open missing")
    ,
        "@qmp_test",
    );
}
