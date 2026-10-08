// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// env.zig — the `makac.env` process-environment and makac-identity submodule.
//
//   makac.env.all() -> { NAME = value, ... }   -- whole process environment
//   makac.env.version() -> major, minor        -- build-time constants
//   makac.env.makac_path() -> path             -- /proc/self/exe, as a path
//
// There is deliberately NO `set` counterpart: per-command environments
// belong to exec's `env` option; mutating process-wide state mid-workflow
// is a footgun nothing needs.

const std = @import("std");
const lua = @import("../lua.zig");
const reg = @import("register.zig");
const path = @import("path.zig");
const version = @import("version.zig");

const VM = @import("../vm.zig").VM;
const c_alloc = std.heap.c_allocator;

fn vm(L: *lua.State) *VM {
    return @ptrCast(@alignCast(reg.hostContext(L)));
}

fn raiseFmt(L: *lua.State, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "makac.env: error";
    lua.raiseLString(L, msg);
}

/// Called via register.zig's install; adds `all`/`version`/`makac_path` to
/// the shared `makac.env` table.
pub fn registerEnv(L: *lua.State) void {
    reg.pushSubmodule(L, "env");
    defer lua.pop(L, 1);
    lua.pushCFunction(L, envAll);
    lua.setField(L, -2, "all");
    lua.pushCFunction(L, envVersion);
    lua.setField(L, -2, "version");
    lua.pushCFunction(L, envMakacPath);
    lua.setField(L, -2, "makac_path");
}

/// makac.env.all() -> { NAME = value, ... } — the whole process environment
/// as a table. The split is at the FIRST '=' (values may contain '='; names
/// cannot). Length-checked strings throughout: env values are byte arrays.
fn envAll(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    lua.createTable(L, 0, 0);
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const s = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue; // POSIX guarantees name=value
        lua.pushLString(L, s[0..eq]);
        lua.pushLString(L, s[eq + 1 ..]);
        lua.rawSet(L, -3);
    }
    return 1;
}

/// makac.env.version() -> major, minor — the build-time constants, as Lua
/// integers (capability pinning for workflows).
fn envVersion(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    lua.pushInteger(L, version.major);
    lua.pushInteger(L, version.minor);
    return 2;
}

/// makac.env.makac_path() -> path — absolute, canonicalized path of the
/// running makac binary (`/proc/self/exe` on Linux), as a `path` value. For
/// re-invoking makac in an isolated process without trusting $PATH.
fn envMakacPath(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const v = vm(L);
    const p = std.process.executablePathAlloc(v.io, c_alloc) catch |e| {
        raiseFmt(L, "makac.env: makac_path: cannot resolve executable path: {s}", .{@errorName(e)});
    };
    path.pushPathOwned(L, p);
    return 1;
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

test "env submodule: all/version/makac_path" {
    const vm_instance = try VM.new(testing.allocator, testing.io, .{});
    defer vm_instance.deinit();
    // Compare against the single source of truth rather than a hardcoded pair,
    // so a release version bump cannot break the suite.
    const script = try std.fmt.allocPrint(testing.allocator,
        \\local all = makac.env.all()
        \\assert(type(all) == "table")
        \\assert(type(all.PATH) == "string")
        \\-- split at the FIRST '=' only: PATH values are ':'-heavy but harmless
        \\local maj, min = makac.env.version()
        \\assert(type(maj) == "number" and type(min) == "number")
        \\assert(maj == {d} and min == {d})
        \\local p = makac.env.makac_path()
        \\assert(type(p) ~= "string", "makac_path returns a path value")
        \\local s = tostring(p)
        \\assert(s:sub(1, 1) == "/", "makac_path is absolute")
        \\assert(makac.fs.stat(s) ~= nil, "the binary exists")
    , .{ version.major, version.minor });
    defer testing.allocator.free(script);
    try vm_instance.runString(script, "@env_test");
}
