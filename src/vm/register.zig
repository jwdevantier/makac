// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// register.zig — registration glue for the zig-side Lua primitives.
//
// Every host primitive exposed to Lua lives at makac.<name>; submodule areas
// (time, fs, json, env, ...) live at makac.<name>.<field> behind one shared
// table per name.

const std = @import("std");
const lua = @import("../lua.zig");

/// `register(L, "exec", f)` adds f to the global `makac` table under `name`,
/// creating the table when it does not exist yet.
pub fn register(L: *lua.State, name: [:0]const u8, f: lua.CFunction) void {
    _ = lua.getGlobal(L, "makac");
    if (lua.typeOf(L, -1) != lua.TTABLE) {
        lua.pop(L, 1);
        lua.createTable(L, 0, 8);
        lua.pushvalue(L, -1);
        lua.setGlobal(L, "makac");
    }
    lua.pushCFunction(L, f);
    lua.setField(L, -2, name);
    lua.pop(L, 1);
}

/// Push the `makac.<name>` submodule table, creating and registering it when
/// absent. Exactly one table per name survives across registration passes.
/// The caller pops the pushed table.
pub fn pushSubmodule(L: *lua.State, name: [:0]const u8) void {
    _ = lua.getGlobal(L, "makac");
    if (lua.typeOf(L, -1) != lua.TTABLE) {
        lua.pop(L, 1);
        lua.createTable(L, 0, 8);
        lua.pushvalue(L, -1);
        lua.setGlobal(L, "makac");
    }
    if (lua.typeOf(L, lua.getField(L, -1, name)) == lua.TTABLE) {
        lua.remove(L, -2); // keep submodule, drop makac
        return;
    }
    lua.pop(L, 1); // the non-table field
    lua.createTable(L, 0, 8);
    lua.pushvalue(L, -1);
    lua.setField(L, -3, name);
    lua.remove(L, -2); // keep submodule, drop makac
}

/// Install every host primitive the current task set needs. Called by
/// `vm.VM.registerBuiltins` before the embedded prelude is evaluated.
pub fn install(L: *lua.State) void {
    @import("exec.zig").registerExec(L);
    @import("time.zig").registerTime(L);
    @import("json.zig").registerJson(L);
    @import("env.zig").registerEnv(L);
    @import("random.zig").registerRandom(L);
    @import("proc.zig").registerProc(L);
    @import("spawn.zig").registerSpawn(L);
    @import("fs.zig").registerFs(L);
    @import("fetch.zig").registerFetch(L);
    @import("qmp.zig").registerQmp(L);
    @import("ssh_target.zig").registerSshTarget(L);
}

/// The `*vm.VM` pointer stashed in the Lua registry by `VM.new` under the
/// key "makac.vm". Host primitives that need the VM's `io`/allocator fetch
/// it through here from a bare `lua_State`.
pub fn hostContext(L: *lua.State) *anyopaque {
    _ = lua.getField(L, lua.REGISTRYINDEX, "makac.vm");
    const p = lua.toUserdata(L, -1) orelse unreachable;
    lua.pop(L, 1);
    return p;
}

test "register creates makac and adds a field; submodule is single" {
    const L = lua.newState() orelse return error.OutOfMemory;
    defer lua.close(L);
    lua.openlibs(L);

    register(L, "exec", noop);
    _ = lua.getGlobal(L, "makac");
    try std.testing.expect(lua.typeOf(L, -1) == lua.TTABLE);
    _ = lua.getField(L, -1, "exec");
    try std.testing.expect(lua.isFunction(L, -1));
    lua.pop(L, 2);

    // Two passes resolve the SAME submodule table.
    pushSubmodule(L, "time");
    lua.pushInteger(L, 42);
    lua.setField(L, -2, "probe");
    pushSubmodule(L, "time");
    lua.pop(L, 1); // drop the second reference
    _ = lua.getField(L, -1, "probe");
    try std.testing.expectEqual(@as(lua.Integer, 42), lua.toInteger(L, -1));
    lua.pop(L, 2);
}

fn noop(_: ?*lua.State) callconv(.c) c_int {
    return 0;
}
