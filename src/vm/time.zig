// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// time.zig — makac.time, the poll-loop primitives Lua lacks.
//
// One unit everywhere: integer nanoseconds. `now` is CLOCK_MONOTONIC
// (never wall time) so deadline arithmetic is safe across NTP jumps; `sleep`
// is nanosleep with EINTR resume.

const std = @import("std");
const lua = @import("../lua.zig");
const reg = @import("register.zig");
const linux = std.os.linux;

/// 10 years in nanoseconds: a larger sleep request is a caller bug (unit
/// confusion), not a legitimate wait.
const max_sleep_ns: i64 = 10 * 365 * 24 * 60 * 60 * 1_000_000_000;

pub fn registerTime(L: *lua.State) void {
    reg.pushSubmodule(L, "time");
    defer lua.pop(L, 1);

    lua.pushCFunction(L, timeNow);
    lua.setField(L, -2, "now");
    lua.pushCFunction(L, timeSleep);
    lua.setField(L, -2, "sleep");
    lua.pushInteger(L, 1_000);
    lua.setField(L, -2, "ns_per_us");
    lua.pushInteger(L, 1_000_000);
    lua.setField(L, -2, "ns_per_ms");
    lua.pushInteger(L, 1_000_000_000);
    lua.setField(L, -2, "ns_per_s");
}

/// makac.time.now() -> integer — CLOCK_MONOTONIC in nanoseconds.
fn timeNow(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) {
        lua.raise(L, "makac.time.now: clock_gettime(CLOCK_MONOTONIC) failed");
    }
    const ns: i64 = @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
    lua.pushInteger(L, ns);
    return 1;
}

/// makac.time.sleep(ns) — suspend for ns nanoseconds; resumes on EINTR.
fn timeSleep(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const ns = lua.checkInteger(L, 1);
    if (ns < 0) lua.raise(L, "makac.time.sleep: ns must not be negative");
    if (ns > max_sleep_ns) {
        lua.raise(L, "makac.time.sleep: ns is absurdly large (max 10 years)");
    }
    var req = linux.timespec{
        .sec = @intCast(@divTrunc(ns, 1_000_000_000)),
        .nsec = @intCast(@mod(ns, 1_000_000_000)),
    };
    while (true) {
        var rem: linux.timespec = undefined;
        const e = linux.errno(linux.nanosleep(&req, &rem));
        if (e == .SUCCESS) break;
        if (e == .INTR) {
            req = rem;
            continue;
        }
        lua.raise(L, "makac.time.sleep: nanosleep failed");
    }
    return 0;
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

test "time submodule exposes now/sleep and the unit constants" {
    const L = lua.newState() orelse return error.OutOfMemory;
    defer lua.close(L);
    lua.openlibs(L);
    registerTime(L);

    try testing.expect(lua.OK == lua.loadBuffer(L, "t = makac.time", "@t"));
    try testing.expect(lua.OK == lua.pcall(L, 0, 0, 0));
    try testing.expect(lua.OK == lua.loadBuffer(
        L,
        \\assert(type(t) == "table")
        \\assert(type(t.now) == "function")
        \\assert(type(t.sleep) == "function")
        \\assert(t.ns_per_us == 1000 and t.ns_per_ms == 1000000 and t.ns_per_s == 1000000000)
    ,
        "@t",
    ));
    try testing.expect(lua.OK == lua.pcall(L, 0, 0, 0));
}

test "time.now is monotonic and advances" {
    const L = lua.newState() orelse return error.OutOfMemory;
    defer lua.close(L);
    lua.openlibs(L);
    registerTime(L);

    try testing.expect(lua.OK == lua.loadBuffer(
        L,
        \\local a = makac.time.now()
        \\makac.time.sleep(2 * makac.time.ns_per_ms)
        \\local b = makac.time.now()
        \\assert(math.type(a) == "integer")
        \\assert(b > a)
    ,
        "@t",
    ));
    try testing.expect(lua.OK == lua.pcall(L, 0, 0, 0));
}
