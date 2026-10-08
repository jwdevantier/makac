// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// luals.zig — the embedded LuaCATS stub for makac's injected globals and Lua
// stdlib extensions (design/luacats.md).
//
// The stub is vendored verbatim at `luals/makac.lua` and baked into the binary
// like the prelude, so the types always match the running version — no separate
// artifact to install or pin. The prelude's `makac._luals_setup` reads it back
// from `makac._luals_stub` and writes it into a project's data directory
// (plus `pkgs/<alias>` symlinks and `.luarc.json`). Definitions-only; never
// executed.

const std = @import("std");
const lua = @import("../lua.zig");
const VM = @import("../vm.zig").VM;

/// The LuaCATS stub source, embedded in the binary.
pub const stub = @embedFile("luals/makac.lua");

/// Publish the embedded stub as `makac._luals_stub`. Called after the prelude
/// has run, so the `makac` table already exists.
pub fn exposeStub(v: *VM) void {
    const L = v.L;
    _ = lua.getGlobal(L, "makac");
    lua.pushLString(L, stub);
    lua.setField(L, -2, "_luals_stub");
    lua.pop(L, 1);
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

test "luals stub is embedded and exposed as makac._luals_stub" {
    const vm = try VM.new(testing.allocator, testing.io, .{});
    defer vm.deinit();
    try vm.runString(
        \\assert(type(makac._luals_stub) == "string", "stub not exposed")
        \\assert(makac._luals_stub:find("---@class Makac", 1, true) ~= nil, "not the stub")
        \\assert(type(makac._luals_setup) == "function", "_luals_setup missing")
    , "@luals_test");
}
