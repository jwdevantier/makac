// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// path.zig — the `makac.path` userdata type (a cleaned path string).
//
// A userdata with metatable "makac.path" that owns ONE cleaned path string.
// `tostring(p)` is the escape hatch; every fs function taking a path accepts
// a string or a path value (checkPathString).
//
// `makac.path` implements `__eq` for value-equality checks over the stored
// path strings. Comparison against a bare string still yields false
// (Lua never dispatches `__eq` across types).
//
//   makac.fs.path(s) -> path
//   makac.fs.path_join(a, b, ...) -> path   (variadic; "" dropped)
//   makac.fs.null_file() -> path            ("/dev/null")
//   makac.fs.sep                            ("/")
//   p:dirname() -> path    p:basename() -> string    p:join(...) -> path

const std = @import("std");
const lua = @import("../lua.zig");

pub const MT: [:0]const u8 = "makac.path";

/// Userdata payload: an owned cleaned path. Freed by `__gc`.
const PathValue = struct {
    raw: []u8,
};

fn oom(L: *lua.State) noreturn {
    lua.raiseLString(L, "makac.fs: out of memory");
}

/// `string or path expected (#idx) (got type)` — the coercion error every
/// path-taking fs function raises.
fn raisePathType(L: *lua.State, idx: c_int) noreturn {
    var buf: [256]u8 = undefined;
    const tn = std.mem.span(lua.typeName(L, idx));
    const msg = std.fmt.bufPrint(
        &buf,
        "string or path expected (#{d}) (got {s})",
        .{ idx, tn },
    ) catch "string or path expected";
    lua.raiseLString(L, msg);
}

/// Accept a Lua string or a `makac.path` userdata; returns the underlying
/// bytes (a view into the Lua string / userdata, valid while the value sits
/// on the stack). Anything else raises.
pub fn checkPathString(L: *lua.State, idx: c_int) []const u8 {
    switch (lua.typeOf(L, idx)) {
        lua.TSTRING => return lua.checkLString(L, idx),
        lua.TUSERDATA => {
            if (lua.checkUdata(L, idx, MT)) |p| {
                const self: *PathValue = @ptrCast(@alignCast(p));
                return self.raw;
            }
        },
        else => {},
    }
    raisePathType(L, idx);
}

/// Push a new path value wrapping a copy of `raw`.
pub fn pushPath(L: *lua.State, raw: []const u8) void {
    const copy = std.heap.c_allocator.dupe(u8, raw) catch oom(L);
    pushPathOwned(L, copy);
}

/// Push a new path value taking ownership of `raw` (allocated with the
/// c_allocator). `__gc` frees it.
pub fn pushPathOwned(L: *lua.State, raw: []u8) void {
    const self: *PathValue = lua.newUserdata(L, PathValue);
    self.* = .{ .raw = raw };
    lua.setMetatable(L, MT);
}

/// POSIX path.Clean (the `core:path/filepath.clean` the reference uses).
pub fn cleanPosix(allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]u8 {
    if (path.len == 0) return allocator.dupe(u8, ".");

    const rooted = path[0] == '/';
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var r: usize = 0;
    var dotdot: usize = 0;
    if (rooted) {
        try out.append(allocator, '/');
        r = 1;
        dotdot = 1;
    }
    const n = path.len;
    while (r < n) {
        if (path[r] == '/') {
            r += 1;
        } else if (path[r] == '.' and (r + 1 == n or path[r + 1] == '/')) {
            r += 1;
        } else if (path[r] == '.' and r + 1 < n and path[r + 1] == '.' and
            (r + 2 == n or path[r + 2] == '/'))
        {
            r += 2;
            if (out.items.len > dotdot) {
                var w = out.items.len - 1;
                while (w > dotdot and out.items[w] != '/') w -= 1;
                out.items.len = w;
            } else if (!rooted) {
                if (out.items.len > 0) try out.append(allocator, '/');
                try out.appendSlice(allocator, "..");
                dotdot = out.items.len;
            }
        } else {
            if ((rooted and out.items.len != 1) or (!rooted and out.items.len != 0)) {
                try out.append(allocator, '/');
            }
            while (r < n and path[r] != '/') {
                try out.append(allocator, path[r]);
                r += 1;
            }
        }
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return allocator.dupe(u8, ".");
    }
    return try out.toOwnedSlice(allocator);
}

fn selfPath(L: *lua.State) *PathValue {
    const p = lua.checkUdata(L, 1, MT) orelse unreachable;
    return @ptrCast(@alignCast(p));
}

// ---------------------------------------------------------- metamethods ----

fn pathIndex(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    if (lua.typeOf(L, 2) != lua.TSTRING) {
        lua.pushNil(L);
        return 1;
    }
    const key = lua.toLString(L, 2) orelse {
        lua.pushNil(L);
        return 1;
    };
    if (std.mem.eql(u8, key, "dirname")) {
        lua.pushCFunction(L, pathDirname);
    } else if (std.mem.eql(u8, key, "basename")) {
        lua.pushCFunction(L, pathBasename);
    } else if (std.mem.eql(u8, key, "join")) {
        lua.pushCFunction(L, pathJoinMethod);
    } else {
        lua.pushNil(L);
    }
    return 1;
}

fn pathGc(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const p = lua.toUserdata(L, 1) orelse return 0;
    const self: *PathValue = @ptrCast(@alignCast(p));
    std.heap.c_allocator.free(self.raw);
    self.raw = &.{};
    return 0;
}

fn pathTostring(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    lua.pushLString(L, selfPath(L).raw);
    return 1;
}

fn pathEq(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const a = selfPath(L);
    const b: *PathValue = @ptrCast(@alignCast(lua.checkUdata(L, 2, MT) orelse unreachable));
    lua.pushBoolean(L, std.mem.eql(u8, a.raw, b.raw));
    return 1;
}

// -------------------------------------------------------------- methods ----

fn pathDirname(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const raw = selfPath(L).raw;
    const d = if (std.mem.eql(u8, raw, "/"))
        "/"
    else
        std.fs.path.dirname(raw) orelse ".";
    pushPath(L, d);
    return 1;
}

fn pathBasename(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    lua.pushLString(L, std.fs.path.basename(selfPath(L).raw));
    return 1;
}

fn pathJoinMethod(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    return joinArgsPush(L, 1);
}

// ----------------------------------------------------------- fs entries ----

/// Shared variadic join: drop "" elements, join, clean. An all-empty list
/// yields the empty path (matching the reference's special case).
fn joinArgsPush(L: *lua.State, from: c_int) c_int {
    const argc = lua.gettop(L);
    var elems: std.ArrayList([]const u8) = .empty;
    defer elems.deinit(std.heap.c_allocator);

    var i = from;
    while (i <= argc) : (i += 1) {
        const e = checkPathString(L, i);
        if (e.len > 0) {
            elems.append(std.heap.c_allocator, e) catch oom(L);
        }
    }
    if (elems.items.len == 0) {
        pushPath(L, "");
        return 1;
    }
    const joined = std.fs.path.join(std.heap.c_allocator, elems.items) catch oom(L);
    defer std.heap.c_allocator.free(joined);
    const cleaned = cleanPosix(std.heap.c_allocator, joined) catch oom(L);
    pushPathOwned(L, cleaned);
    return 1;
}

fn fsPath(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const raw = checkPathString(L, 1);
    const cleaned = cleanPosix(std.heap.c_allocator, raw) catch oom(L);
    pushPathOwned(L, cleaned);
    return 1;
}

fn fsPathJoin(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    return joinArgsPush(L, 1);
}

fn fsNullFile(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    pushPath(L, "/dev/null");
    return 1;
}

/// Called while the `makac.fs` submodule table is on top of the stack.
pub fn registerPathOnFs(L: *lua.State) void {
    if (lua.newMetatable(L, MT)) {
        lua.pushCFunction(L, pathIndex);
        lua.setField(L, -2, "__index");
        lua.pushCFunction(L, pathGc);
        lua.setField(L, -2, "__gc");
        lua.pushCFunction(L, pathTostring);
        lua.setField(L, -2, "__tostring");
        lua.pushCFunction(L, pathEq);
        lua.setField(L, -2, "__eq");
    }
    lua.pop(L, 1); // the metatable

    lua.pushCFunction(L, fsPath);
    lua.setField(L, -2, "path");
    lua.pushCFunction(L, fsPathJoin);
    lua.setField(L, -2, "path_join");
    lua.pushCFunction(L, fsNullFile);
    lua.setField(L, -2, "null_file");
    lua.pushStringZ(L, "/");
    lua.setField(L, -2, "sep");
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

test "cleanPosix matches path.Clean" {
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "", .out = "." },
        .{ .in = "/", .out = "/" },
        .{ .in = "/tmp/x.txt", .out = "/tmp/x.txt" },
        .{ .in = "foo/", .out = "foo" },
        .{ .in = "/a//b", .out = "/a/b" },
        .{ .in = "./x", .out = "x" },
        .{ .in = "a/../b", .out = "b" },
        .{ .in = "/a/b/c/../../", .out = "/a" },
        .{ .in = "a/..", .out = "." },
        .{ .in = "/a/..", .out = "/" },
        .{ .in = "../a", .out = "../a" },
    };
    for (cases) |c| {
        const got = try cleanPosix(testing.allocator, c.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.out, got);
    }
}

test "path userdata: tostring, dirname/basename edges, value equality" {
    const L = lua.newState() orelse return error.OutOfMemory;
    defer lua.close(L);
    lua.openlibs(L);

    // fs submodule + path registration
    @import("register.zig").pushSubmodule(L, "fs");
    registerPathOnFs(L);
    lua.pop(L, 1);

    const src =
        \\local p = makac.fs.path
        \\assert(tostring(p("/a/b/c.txt")) == "/a/b/c.txt")
        \\assert(p("/a/b/c.txt"):basename() == "c.txt")
        \\assert(type(p("/a/b/c.txt"):basename()) == "string")
        \\assert(type(p("/a/b/c.txt"):dirname()) == "userdata")
        \\assert(tostring(p("/a/b/c.txt"):dirname()) == "/a/b")
        \\assert(p("foo/"):basename() == "foo")
        \\assert(tostring(p("/"):dirname()) == "/")
        \\assert(p("/"):basename() == "")
        \\assert(tostring(makac.fs.path("/a"):join("b", "c.txt")) == "/a/b/c.txt")
        \\assert(tostring(makac.fs.path_join("/a", "b", "", "c")) == "/a/b/c")
        \\assert(tostring(makac.fs.null_file()) == "/dev/null")
        \\assert(makac.fs.sep == "/")
        \\assert(p("/x") == p("/x"))
        \\assert(not (p("/x") == p("/y")))
        \\assert(not (p("/x") == "/x"))
    ;
    try testing.expect(lua.OK == lua.loadBuffer(L, src, "@path_test"));
    try testing.expect(lua.OK == lua.pcall(L, 0, 0, 0));
}
