// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// proc.zig — flat process primitives (`makac.pid_alive`).
//
// Process probes are flat under makac.* (the orchestrator vocabulary), not
// a submodule. `makac.spawn`, the captured stdio sibling, lives in
// vm/spawn.zig; `makac.exec` lives in vm/exec.zig.

const std = @import("std");
const lua = @import("../lua.zig");
const reg = @import("register.zig");
const linux = std.os.linux;

pub fn registerProc(L: *lua.State) void {
    reg.register(L, "pid_alive", pidAlive);
}

/// makac.pid_alive(pid) -> bool — ONE kill(pid, 0) syscall. `false` for
/// ESRCH (no such pid), `true` for EPERM (the process exists even when it
/// is not ours — shelling out to `kill -0` cannot tell the two apart
/// without stderr parsing), `true` on success. NEVER raises: the answer is
/// a boolean, not an exception.
fn pidAlive(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    // L_checkinteger raises on non-numeric args — bad argument types are
    // argument misuse, not a syscall result, and raise per convention.
    const pid = lua.checkInteger(L, 1);
    const rc = linux.kill(@intCast(pid), @enumFromInt(0));
    const e = linux.errno(rc);
    if (e == .SUCCESS) {
        lua.pushBoolean(L, true);
    } else {
        lua.pushBoolean(L, e != .SRCH);
    }
    return 1;
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

test "pid_alive: self is alive, a bogus pid is not" {
    const L = lua.newState() orelse return error.OutOfMemory;
    defer lua.close(L);
    lua.openlibs(L);
    registerProc(L);

    const self_pid = linux.getpid();
    var src_buf: [256]u8 = undefined;
    const src = std.fmt.bufPrint(
        &src_buf,
        \\assert(makac.pid_alive({d}) == true)
        \\assert(makac.pid_alive(4194303) == false)
        \\assert(not pcall(makac.pid_alive, "nope"))
    ,
        .{self_pid},
    ) catch unreachable;
    try testing.expect(lua.OK == lua.loadBuffer(L, src, "@pid_alive_test"));
    try testing.expect(lua.OK == lua.pcall(L, 0, 0, 0));
}
