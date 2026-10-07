// SPDX-License-Identifier: BSD-2-Clause
// SPIKE — experiments/direct-c: stock Lua 5.4 embedded via the raw C API,
// the same shape the Odin reference uses (vendor:lua/5.4). This file is the
// scaffold seed for the real port; today it just proves the embedding works:
// create state, openlibs, register one host function, eval a string.
//
// The mapping to Odin's calls is 1:1:
//   odin  lua.L_newstate()   == zig  c.luaL_newstate()
//   odin  lua.L_openlibs(st) == zig  c.luaL_openlibs(st)
//   odin  lua.L_dostring ... == zig  luaL_loadstring + lua_pcall

const std = @import("std");

// The lua C sources live in the "lua" module (see build.zig).
const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

// translate-c handles lua.h's macros badly in places; call the underlying
// real functions (pcallk, optlstring, tolstring). The port will wrap these
// in a small internal helper layer — mirroring how Odin's vendored binding
// did it.

fn hostEcho(L: ?*c.lua_State) callconv(.c) c_int {
    const s = c.luaL_optlstring(L, 1, "world", null); // lstring: macro-safe form
    _ = c.lua_pushstring(L, s);
    return 1;
}

pub fn main() u8 {
    const L = c.luaL_newstate() orelse return 1;
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    c.lua_pushcfunction(L, hostEcho);
    c.lua_setglobal(L, "host_echo");

    const src: [:0]const u8 =
        \\print("lua says: " .. _VERSION)
        \\io.write("host says: ", tostring(host_echo("makac (zig, direct C API)")), "\n")
    ;
    if (c.luaL_loadstring(L, src.ptr) != c.LUA_OK or
        c.lua_pcallk(L, 0, 0, 0, 0, null) != c.LUA_OK)
    {
        var n: usize = 0;
        const msg = c.lua_tolstring(L, -1, &n);
        std.debug.print("lua error: {s}\n", .{msg[0..n]});
        return 1;
    }
    return 0;
}
