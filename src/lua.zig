// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// lua.zig — a thin, NUL-safe internal wrapper over the stock Lua 5.4 C API.
//
// Lua strings are byte arrays: every string that crosses this boundary goes
// through explicit lengths (`lua_pushlstring` / `lua_tolstring` /
// `luaL_checklstring`), never a C-string conversion.
//
// translate-c mangles several `lua.h` macros; where that matters we call the
// underlying real functions (e.g. `lua_pcallk` instead of the `lua_pcall`
// macro).

const std = @import("std");

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

pub const State = c.lua_State;
pub const CFunction = c.lua_CFunction;
pub const KContext = c.lua_KContext;
pub const Integer = c.lua_Integer;
pub const Number = c.lua_Number;

pub const OK: c_int = c.LUA_OK;
pub const MULTRET: c_int = c.LUA_MULTRET;
pub const REGISTRYINDEX: c_int = c.LUA_REGISTRYINDEX;

// lua_type() results
pub const TNIL: c_int = c.LUA_TNIL;
pub const TBOOLEAN: c_int = c.LUA_TBOOLEAN;
pub const TLIGHTUSERDATA: c_int = c.LUA_TLIGHTUSERDATA;
pub const TNUMBER: c_int = c.LUA_TNUMBER;
pub const TSTRING: c_int = c.LUA_TSTRING;
pub const TTABLE: c_int = c.LUA_TTABLE;
pub const TFUNCTION: c_int = c.LUA_TFUNCTION;
pub const TUSERDATA: c_int = c.LUA_TUSERDATA;
pub const TTHREAD: c_int = c.LUA_TTHREAD;

// ---------------------------------------------------------------- state ----

pub fn newState() ?*State {
    return c.luaL_newstate();
}

pub fn close(L: *State) void {
    c.lua_close(L);
}

pub fn openlibs(L: *State) void {
    c.luaL_openlibs(L);
}

// ------------------------------------------------------------ stack ops ----

pub fn gettop(L: *State) c_int {
    return c.lua_gettop(L);
}

pub fn settop(L: *State, idx: c_int) void {
    c.lua_settop(L, idx);
}

pub fn pop(L: *State, n: c_int) void {
    c.lua_settop(L, -n - 1);
}

pub fn pushvalue(L: *State, idx: c_int) void {
    c.lua_pushvalue(L, idx);
}

pub fn rotate(L: *State, idx: c_int, n: c_int) void {
    c.lua_rotate(L, idx, n);
}

pub fn remove(L: *State, idx: c_int) void {
    c.lua_rotate(L, idx, -1);
    pop(L, 1);
}

/// Convert a (possibly relative) stack index to an absolute one; the index
/// stays valid as long as the value is not popped.
pub fn absindex(L: *State, idx: c_int) c_int {
    return c.lua_absindex(L, idx);
}

pub fn typeOf(L: *State, idx: c_int) c_int {
    return c.lua_type(L, idx);
}

pub fn typeName(L: *State, idx: c_int) [*c]const u8 {
    return c.lua_typename(L, c.lua_type(L, idx));
}

pub fn isNil(L: *State, idx: c_int) bool {
    return c.lua_type(L, idx) == TNIL;
}

pub fn isNoneOrNil(L: *State, idx: c_int) bool {
    return c.lua_type(L, idx) <= 0;
}

pub fn isTable(L: *State, idx: c_int) bool {
    return c.lua_type(L, idx) == TTABLE;
}

pub fn isFunction(L: *State, idx: c_int) bool {
    return c.lua_type(L, idx) == TFUNCTION;
}

pub fn isString(L: *State, idx: c_int) bool {
    return c.lua_type(L, idx) == TSTRING;
}

pub fn isUserdata(L: *State, idx: c_int) bool {
    return c.lua_type(L, idx) == TUSERDATA;
}

// --------------------------------------------------------- load / call -----

/// Load a byte-exact source buffer. `chunk_name` must be NUL-terminated and
/// conventionally starts with '@' for files. Returns the Lua status code.
pub fn loadBuffer(L: *State, src: []const u8, chunk_name: [:0]const u8) c_int {
    // Call the real function: translate-c's `luaL_loadbuffer` inline wrapper
    // mis-casts its `NULL` mode argument.
    return c.luaL_loadbufferx(L, src.ptr, src.len, chunk_name.ptr, null);
}

/// The real call primitive. `lua_pcall` is a macro that translate-c mangles;
/// this is exactly what it expands to.
pub fn pcall(L: *State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int {
    return c.lua_pcallk(L, nargs, nresults, errfunc, 0, null);
}

/// Pop the error message left on top by a failed pcall and return a slice
/// into it (valid until the value is popped). Callers that need it past the
/// pop must copy.
pub fn peekError(L: *State) []const u8 {
    return toLString(L, -1) orelse "<no error message>";
}

// ------------------------------------------------------------- strings -----

pub fn pushLString(L: *State, s: []const u8) void {
    _ = c.lua_pushlstring(L, s.ptr, s.len);
}

pub fn pushStringZ(L: *State, s: [:0]const u8) void {
    _ = c.lua_pushstring(L, s.ptr);
}

/// NUL-safe conversion: returns the exact bytes, length included, or null if
/// the value is not a string/number.
pub fn toLString(L: *State, idx: c_int) ?[]const u8 {
    var len: usize = 0;
    const p = c.lua_tolstring(L, idx, &len);
    if (p == null) return null;
    const bp: [*]const u8 = @ptrCast(p);
    return bp[0..len];
}

/// Checked string argument (raises a Lua error on a non-string).
pub fn checkLString(L: *State, arg: c_int) []const u8 {
    var len: usize = 0;
    const p = c.luaL_checklstring(L, arg, &len);
    const bp: [*]const u8 = @ptrCast(p);
    return bp[0..len];
}

/// Optional string argument; `def` must be NUL-terminated.
pub fn optLString(L: *State, arg: c_int, def: [:0]const u8) []const u8 {
    var len: usize = 0;
    const p = c.luaL_optlstring(L, arg, def.ptr, &len);
    if (p == null) return def;
    const bp: [*]const u8 = @ptrCast(p);
    return bp[0..len];
}

// ------------------------------------------------------------- numbers -----

pub fn pushNil(L: *State) void {
    c.lua_pushnil(L);
}

pub fn pushInteger(L: *State, n: Integer) void {
    c.lua_pushinteger(L, n);
}

pub fn pushNumber(L: *State, n: Number) void {
    c.lua_pushnumber(L, n);
}

pub fn pushBoolean(L: *State, b: bool) void {
    c.lua_pushboolean(L, @intFromBool(b));
}

pub fn toBoolean(L: *State, idx: c_int) bool {
    return c.lua_toboolean(L, idx) != 0;
}

pub fn toInteger(L: *State, idx: c_int) Integer {
    return c.lua_tointegerx(L, idx, null);
}

pub fn toNumber(L: *State, idx: c_int) Number {
    return c.lua_tonumberx(L, idx, null);
}

pub fn checkInteger(L: *State, arg: c_int) Integer {
    return c.luaL_checkinteger(L, arg);
}

pub fn optInteger(L: *State, arg: c_int, def: Integer) Integer {
    return c.luaL_optinteger(L, arg, def);
}

pub fn checkNumber(L: *State, arg: c_int) Number {
    return c.luaL_checknumber(L, arg);
}

// -------------------------------------------------------------- tables -----

pub fn createTable(L: *State, narr: c_int, nrec: c_int) void {
    _ = c.lua_createtable(L, narr, nrec);
}

pub fn rawGetI(L: *State, idx: c_int, n: Integer) c_int {
    return c.lua_rawgeti(L, idx, n);
}

pub fn rawSetI(L: *State, idx: c_int, n: Integer) void {
    c.lua_rawseti(L, idx, n);
}

pub fn rawGet(L: *State, idx: c_int) c_int {
    return c.lua_rawget(L, idx);
}

pub fn rawSet(L: *State, idx: c_int) void {
    c.lua_rawset(L, idx);
}

pub fn getField(L: *State, idx: c_int, k: [:0]const u8) c_int {
    return c.lua_getfield(L, idx, k.ptr);
}

pub fn setField(L: *State, idx: c_int, k: [:0]const u8) void {
    c.lua_setfield(L, idx, k.ptr);
}

pub fn getGlobal(L: *State, k: [:0]const u8) c_int {
    return c.lua_getglobal(L, k.ptr);
}

pub fn setGlobal(L: *State, k: [:0]const u8) void {
    c.lua_setglobal(L, k.ptr);
}

pub fn rawLen(L: *State, idx: c_int) usize {
    return c.lua_rawlen(L, idx);
}

/// Iterate a table at `idx`: on entry the key is on top; returns 1 and leaves
/// key/value on top when there is a next pair, 0 and pops the key otherwise.
pub fn next(L: *State, idx: c_int) c_int {
    return c.lua_next(L, idx);
}

// ------------------------------------------------------------ functions ----

pub fn pushCClosure(L: *State, f: CFunction, nup: c_int) void {
    c.lua_pushcclosure(L, f, nup);
}

pub fn pushCFunction(L: *State, f: CFunction) void {
    c.lua_pushcclosure(L, f, 0);
}

pub fn insert(L: *State, idx: c_int) void {
    c.lua_insert(L, idx);
}

pub fn pushLightUserdata(L: *State, p: ?*anyopaque) void {
    c.lua_pushlightuserdata(L, p);
}

// -------------------------------------------------------------- errors -----

/// Raise a Lua error with a plain (no-format) message. Never returns.
pub fn raise(L: *State, msg: [:0]const u8) noreturn {
    _ = c.luaL_error(L, msg.ptr);
    unreachable;
}

/// Raise a Lua error whose message is an arbitrary byte string (no format
/// interpretation). The bytes are copied into the Lua heap before raising, so
/// the caller may free its buffer. Never returns.
pub fn raiseLString(L: *State, msg: []const u8) noreturn {
    pushLString(L, msg);
    _ = c.lua_error(L);
    unreachable;
}

pub fn checkType(L: *State, arg: c_int, t: c_int) void {
    c.luaL_checktype(L, arg, t);
}

pub fn checkAny(L: *State, arg: c_int) void {
    c.luaL_checkany(L, arg);
}

pub fn argError(L: *State, arg: c_int, msg: [:0]const u8) c_int {
    return c.luaL_argerror(L, arg, msg.ptr);
}

pub fn throw(L: *State) c_int {
    return c.lua_error(L);
}

// ------------------------------------------------------------- userdata ----

pub fn newUserdataRaw(L: *State, size: usize) *anyopaque {
    const p = c.lua_newuserdatauv(L, size, 0) orelse unreachable;
    return p;
}

pub fn newUserdata(L: *State, comptime T: type) *T {
    const p = newUserdataRaw(L, @sizeOf(T));
    return @ptrCast(@alignCast(p));
}

pub fn toUserdata(L: *State, idx: c_int) ?*anyopaque {
    return c.lua_touserdata(L, idx);
}

/// Create the named metatable in the registry if absent (returns true when
/// newly created); leaves exactly one value (the metatable) on the stack.
pub fn newMetatable(L: *State, name: [:0]const u8) bool {
    return c.luaL_newmetatable(L, name.ptr) != 0;
}

pub fn setMetatable(L: *State, name: [:0]const u8) void {
    c.luaL_setmetatable(L, name.ptr);
}

pub fn getMetatableField(L: *State, name: [:0]const u8) void {
    _ = c.luaL_getmetatable(L, name.ptr);
}

/// Checked userdata: raises unless the value at `arg` is userdata carrying the
/// named metatable.
pub fn checkUdata(L: *State, arg: c_int, name: [:0]const u8) ?*anyopaque {
    return c.luaL_checkudata(L, arg, name.ptr);
}

/// A single method table entry for `setFuncs`.
pub const FuncReg = struct {
    name: [:0]const u8,
    func: CFunction,
};

/// Install `funcs` as fields of the table on top of the stack.
pub fn setFuncs(L: *State, funcs: []const FuncReg) void {
    for (funcs) |f| {
        pushCFunction(L, f.func);
        setField(L, -2, f.name);
    }
}

// --------------------------------------------------------------- tests -----

test "NUL-containing string roundtrips through the helpers" {
    const L = newState() orelse return error.OutOfMemory;
    defer close(L);
    openlibs(L);

    const bytes = "a\x00b\x00c";
    pushLString(L, bytes);
    const got = toLString(L, -1) orelse return error.NoString;
    try std.testing.expectEqualSlices(u8, bytes, got);
    pop(L, 1);
}

test "checked string preserves embedded NUL" {
    const L = newState() orelse return error.OutOfMemory;
    defer close(L);
    openlibs(L);

    const bytes = "x\x00y";
    pushLString(L, bytes);
    const got = checkLString(L, -1);
    try std.testing.expectEqualSlices(u8, bytes, got);
    pop(L, 1);
}
