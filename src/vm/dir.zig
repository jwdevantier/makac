// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// dir.zig — the `makac.fs.Dir` directory-handle userdata.
//
// A Dir owns ONE canonical absolute path (resolved at construction, symlinks
// NOT resolved). Operations take an optional `sub` relative to the root,
// validated: must be relative and must not contain a `..` component
// (violations raise). Path-anchored, not fd-anchored.
//
//   makac.fs.cwd() -> Dir
//   makac.fs.open_dir(path|path_str) -> Dir   -- raises unless exists & is dir
//
//   d:path() -> path
//   d:exists(sub?) -> bool
//   d:touch(sub)          d:make_path(sub)     d:open_dir(sub) -> Dir
//   d:parent() -> Dir     d:list()             d:walk() -> iterator
//   d:remove(sub?)        -- recursive; sub-omitted removes the root
//
// Note: `d:list()` returns `{ name, type }` where `type` is the stat
// vocabulary ("file"|"dir"|"socket"|"link"|"other"), sourced from the
// getdents `d_type` (with an lstat fallback for DT_UNKNOWN). No `is_dir`.

const std = @import("std");
const lua = @import("../lua.zig");
const reg = @import("register.zig");
const path = @import("path.zig");

const VM = @import("../vm.zig").VM;
const c_alloc = std.heap.c_allocator;

pub const DIR_MT: [:0]const u8 = "makac.fs.Dir";
pub const WALK_MT: [:0]const u8 = "makac.fs.walk";

const DirValue = struct {
    root: []u8, // owned (c_allocator); freed by __gc
};

const WalkEntry = struct {
    sub: []u8, // owned (c_allocator)
    kind: []const u8, // static literal
};

const WalkState = struct {
    entries: []WalkEntry, // owned (c_allocator)
    idx: usize,
};

fn vm(L: *lua.State) *VM {
    return @ptrCast(@alignCast(reg.hostContext(L)));
}

fn oom(L: *lua.State) noreturn {
    lua.raiseLString(L, "makac.fs: out of memory");
}

fn raiseFmt(L: *lua.State, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "makac.fs: Dir: error";
    lua.raiseLString(L, msg);
}

/// The stat vocabulary shared with fs.stat (lstat semantics).
pub fn statKindName(k: std.Io.File.Kind) []const u8 {
    return switch (k) {
        .file => "file",
        .directory => "dir",
        .unix_domain_socket => "socket",
        .sym_link => "link",
        else => "other",
    };
}

fn selfDir(L: *lua.State) *DirValue {
    const p = lua.checkUdata(L, 1, DIR_MT) orelse unreachable;
    return @ptrCast(@alignCast(p));
}

// ------------------------------------------------------------ constructors -

/// Absolute+cleaned, symlinks NOT resolved: keep an absolute input as
/// written (cleaned); join a relative input with the process cwd.
fn absPath(L: *lua.State, s: []const u8) []u8 {
    if (std.fs.path.isAbsolute(s)) {
        return path.cleanPosix(c_alloc, s) catch oom(L);
    }
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(vm(L).io, ".", c_alloc) catch
        raiseFmt(L, "makac.fs: open_dir: cannot determine working directory", .{});
    defer c_alloc.free(cwd);
    const joined = std.fs.path.join(c_alloc, &.{ cwd, s }) catch oom(L);
    defer c_alloc.free(joined);
    return path.cleanPosix(c_alloc, joined) catch oom(L);
}

pub fn pushDirOwned(L: *lua.State, abs: []u8) void {
    const self: *DirValue = lua.newUserdata(L, DirValue);
    self.* = .{ .root = abs };
    lua.setMetatable(L, DIR_MT);
}

pub fn pushDir(L: *lua.State, abs: []const u8) void {
    pushDirOwned(L, c_alloc.dupe(u8, abs) catch oom(L));
}

fn fsCwd(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const v = vm(L);
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(v.io, ".", c_alloc) catch |e| {
        raiseFmt(L, "makac.fs: cwd: cannot determine working directory: {s}", .{@errorName(e)});
    };
    pushDirOwned(L, cwd);
    return 1;
}

fn fsOpenDir(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const v = vm(L);
    const s = path.checkPathString(L, 1);
    const abs = absPath(L, s);
    const st = std.Io.Dir.cwd().statFile(v.io, abs, .{ .follow_symlinks = true }) catch {
        c_alloc.free(abs);
        raiseFmt(L, "makac.fs: open_dir: '{s}' does not exist or is not a directory", .{s});
    };
    if (st.kind != .directory) {
        c_alloc.free(abs);
        raiseFmt(L, "makac.fs: open_dir: '{s}' does not exist or is not a directory", .{s});
    }
    pushDirOwned(L, abs);
    return 1;
}

// ---------------------------------------------------------------- sub ------

/// Validate a `sub`: relative, no `..` component. Accepts string-or-path.
fn dirCheckSub(L: *lua.State, idx: c_int) []const u8 {
    const s = path.checkPathString(L, idx);
    if (std.fs.path.isAbsolute(s)) {
        raiseFmt(L, "makac.fs: Dir: sub '{s}' must be relative", .{s});
    }
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) {
            raiseFmt(L, "makac.fs: Dir: sub '{s}' must not contain '..'", .{s});
        }
    }
    return s;
}

/// root + validated sub (cleaned), or a copy of the root when sub is empty.
fn dirJoin(L: *lua.State, root: []const u8, sub: []const u8) []u8 {
    if (sub.len == 0) return c_alloc.dupe(u8, root) catch oom(L);
    const joined = std.fs.path.join(c_alloc, &.{ root, sub }) catch oom(L);
    defer c_alloc.free(joined);
    return path.cleanPosix(c_alloc, joined) catch oom(L);
}

/// Target of an operation whose sub is OPTIONAL (omitted/nil/"" = the root).
fn dirTargetOptional(L: *lua.State, self: *DirValue, idx: c_int) []u8 {
    const sub = if (!lua.isNoneOrNil(L, idx)) dirCheckSub(L, idx) else "";
    return dirJoin(L, self.root, sub);
}

/// Target of an operation whose sub is REQUIRED (touch/make_path/open_dir).
fn dirTargetRequired(L: *lua.State, self: *DirValue, idx: c_int) []u8 {
    if (lua.isNoneOrNil(L, idx)) {
        raiseFmt(L, "makac.fs: Dir: sub argument required (#{d})", .{idx});
    }
    return dirJoin(L, self.root, dirCheckSub(L, idx));
}

// ------------------------------------------------------------ metamethods ---

fn dirIndex(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    if (lua.typeOf(L, 2) != lua.TSTRING) {
        lua.pushNil(L);
        return 1;
    }
    const key = lua.toLString(L, 2) orelse {
        lua.pushNil(L);
        return 1;
    };
    const target: ?lua.CFunction = if (std.mem.eql(u8, key, "path"))
        dirPath
    else if (std.mem.eql(u8, key, "exists"))
        dirExists
    else if (std.mem.eql(u8, key, "touch"))
        dirTouch
    else if (std.mem.eql(u8, key, "make_path"))
        dirMakePath
    else if (std.mem.eql(u8, key, "open_dir"))
        dirOpenDir
    else if (std.mem.eql(u8, key, "parent"))
        dirParent
    else if (std.mem.eql(u8, key, "list"))
        dirList
    else if (std.mem.eql(u8, key, "walk"))
        dirWalk
    else if (std.mem.eql(u8, key, "remove"))
        dirRemove
    else
        null;
    if (target) |f| lua.pushCFunction(L, f) else lua.pushNil(L);
    return 1;
}

fn dirGc(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const p = lua.toUserdata(L, 1) orelse return 0;
    const self: *DirValue = @ptrCast(@alignCast(p));
    c_alloc.free(self.root);
    self.root = &.{};
    return 0;
}

fn dirTostring(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    lua.pushLString(L, selfDir(L).root);
    return 1;
}

// ---------------------------------------------------------------- methods ---

fn dirPath(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    path.pushPath(L, selfDir(L).root);
    return 1;
}

fn dirExists(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = selfDir(L);
    const full = dirTargetOptional(L, self, 2);
    defer c_alloc.free(full);
    var exists = true;
    _ = std.Io.Dir.cwd().statFile(vm(L).io, full, .{ .follow_symlinks = true }) catch |e| {
        exists = e != error.FileNotFound;
    };
    lua.pushBoolean(L, exists);
    return 1;
}

fn dirTouch(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = selfDir(L);
    const full = dirTargetRequired(L, self, 2);
    defer c_alloc.free(full);
    const f = std.Io.Dir.cwd().createFile(vm(L).io, full, .{ .truncate = false }) catch |e| {
        raiseFmt(L, "makac.fs: Dir: touch: cannot touch '{s}': {s}", .{ full, @errorName(e) });
    };
    f.close(vm(L).io);
    return 0;
}

fn dirMakePath(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = selfDir(L);
    const full = dirTargetRequired(L, self, 2);
    defer c_alloc.free(full);
    std.Io.Dir.cwd().createDirPath(vm(L).io, full) catch |e| {
        raiseFmt(L, "makac.fs: Dir: make_path: cannot create directory '{s}': {s}", .{ full, @errorName(e) });
    };
    return 0;
}

fn dirOpenDir(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = selfDir(L);
    const full = dirTargetRequired(L, self, 2);
    const st = std.Io.Dir.cwd().statFile(vm(L).io, full, .{ .follow_symlinks = true }) catch {
        c_alloc.free(full);
        raiseFmt(L, "makac.fs: Dir: open_dir: '{s}' does not exist or is not a directory", .{full});
    };
    if (st.kind != .directory) {
        c_alloc.free(full);
        raiseFmt(L, "makac.fs: Dir: open_dir: '{s}' does not exist or is not a directory", .{full});
    }
    pushDirOwned(L, full);
    return 1;
}

fn dirParent(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const root = selfDir(L).root;
    const d = if (std.mem.eql(u8, root, "/"))
        "/"
    else
        std.fs.path.dirname(root) orelse "/";
    pushDir(L, d);
    return 1;
}

/// Resolve a dirent's kind, falling back to lstat only for DT_UNKNOWN.
fn resolveKind(v: *VM, parent: []const u8, name: []const u8, kind: std.Io.File.Kind) std.Io.File.Kind {
    if (kind != .unknown) return kind;
    var buf: [4096]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ parent, name }) catch return .unknown;
    const st = std.Io.Dir.cwd().statFile(v.io, full, .{ .follow_symlinks = false }) catch return .unknown;
    return st.kind;
}

fn dirList(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const v = vm(L);
    const root = selfDir(L).root;

    var dir = std.Io.Dir.cwd().openDir(v.io, root, .{ .iterate = true }) catch |e| {
        raiseFmt(L, "makac.fs: Dir: list: cannot list directory '{s}': {s}", .{ root, @errorName(e) });
    };
    defer dir.close(v.io);

    lua.createTable(L, 0, 0);
    const out_idx = lua.absindex(L, -1);
    var it = dir.iterate();
    var n: usize = 0;
    while (true) {
        const maybe = it.next(v.io) catch |e| {
            lua.pop(L, 1);
            raiseFmt(L, "makac.fs: Dir: list: cannot list directory '{s}': {s}", .{ root, @errorName(e) });
        };
        const entry = maybe orelse break;
        lua.createTable(L, 0, 2);
        lua.pushLString(L, entry.name);
        lua.setField(L, -2, "name");
        lua.pushLString(L, statKindName(resolveKind(v, root, entry.name, entry.kind)));
        lua.setField(L, -2, "type");
        n += 1;
        lua.rawSetI(L, out_idx, @intCast(n));
    }
    return 1;
}

fn dirRemove(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = selfDir(L);
    const full = dirTargetOptional(L, self, 2);
    defer c_alloc.free(full);
    removeAll(vm(L).io, full) catch |e| {
        raiseFmt(L, "makac.fs: Dir: remove: cannot remove '{s}': {s}", .{ full, @errorName(e) });
    };
    return 0;
}

/// Recursive remove; a missing target is an error (remove is a statement).
fn removeAll(io: std.Io, target: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, target) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        error.IsDir => {
            var dir = try cwd.openDir(io, target, .{ .iterate = true });
            defer dir.close(io);
            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                var buf: [4096]u8 = undefined;
                const child = std.fmt.bufPrint(&buf, "{s}/{s}", .{ target, entry.name }) catch
                    return error.NameTooLong;
                try removeAll(io, child);
            }
            try cwd.deleteDir(io, target);
        },
        else => return e,
    };
}

// ------------------------------------------------------------------ walk ----

fn walkCollect(L: *lua.State, v: *VM, root: []const u8, rel: []const u8, out: *std.ArrayList(WalkEntry)) !void {
    const full = if (rel.len == 0)
        c_alloc.dupe(u8, root) catch oom(L)
    else
        std.fs.path.join(c_alloc, &.{ root, rel }) catch oom(L);
    defer c_alloc.free(full);

    var dir = try std.Io.Dir.cwd().openDir(v.io, full, .{ .iterate = true });
    defer dir.close(v.io);
    var it = dir.iterate();
    while (try it.next(v.io)) |entry| {
        const kind = resolveKind(v, full, entry.name, entry.kind);
        const sub = if (rel.len == 0)
            c_alloc.dupe(u8, entry.name) catch oom(L)
        else
            std.fs.path.join(c_alloc, &.{ rel, entry.name }) catch oom(L);
        try out.append(c_alloc, .{ .sub = sub, .kind = statKindName(kind) });
        if (kind == .directory) {
            try walkCollect(L, v, root, sub, out);
        }
    }
}

fn dirWalk(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const v = vm(L);
    const root = selfDir(L).root;

    var entries: std.ArrayList(WalkEntry) = .empty;
    walkCollect(L, v, root, "", &entries) catch |e| {
        for (entries.items) |ent| c_alloc.free(ent.sub);
        entries.deinit(c_alloc);
        raiseFmt(L, "makac.fs: Dir: walk: cannot walk '{s}': {s}", .{ root, @errorName(e) });
    };

    const st: *WalkState = lua.newUserdata(L, WalkState);
    st.* = .{ .entries = entries.toOwnedSlice(c_alloc) catch oom(L), .idx = 0 };
    lua.setMetatable(L, WALK_MT);
    lua.pushCFunction(L, walkNext);
    lua.insert(L, -2); // [state, fn] -> [fn, state]
    return 2;
}

fn walkStateGc(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const p = lua.toUserdata(L, 1) orelse return 0;
    const st: *WalkState = @ptrCast(@alignCast(p));
    for (st.entries) |ent| c_alloc.free(ent.sub);
    c_alloc.free(st.entries);
    st.entries = &.{};
    return 0;
}

fn walkNext(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const p = lua.checkUdata(L, 1, WALK_MT) orelse unreachable;
    const st: *WalkState = @ptrCast(@alignCast(p));
    if (st.idx >= st.entries.len) {
        lua.pushNil(L);
        return 1;
    }
    const ent = st.entries[st.idx];
    st.idx += 1;
    lua.pushLString(L, ent.sub);
    lua.pushLString(L, ent.kind);
    return 2;
}

// ----------------------------------------------------------- registration ---

/// Called while the `makac.fs` submodule table is on top of the stack.
pub fn registerDirOnFs(L: *lua.State) void {
    if (lua.newMetatable(L, DIR_MT)) {
        lua.pushCFunction(L, dirIndex);
        lua.setField(L, -2, "__index");
        lua.pushCFunction(L, dirGc);
        lua.setField(L, -2, "__gc");
        lua.pushCFunction(L, dirTostring);
        lua.setField(L, -2, "__tostring");
    }
    lua.pop(L, 1);
    if (lua.newMetatable(L, WALK_MT)) {
        lua.pushCFunction(L, walkStateGc);
        lua.setField(L, -2, "__gc");
    }
    lua.pop(L, 1);

    lua.pushCFunction(L, fsCwd);
    lua.setField(L, -2, "cwd");
    lua.pushCFunction(L, fsOpenDir);
    lua.setField(L, -2, "open_dir");
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

fn newTestVM() !*VM {
    return VM.new(testing.allocator, testing.io, .{});
}

test "Dir handle: cwd/open_dir/touch/make_path/parent/list/walk/remove" {
    const v = try newTestVM();
    defer v.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const src = try std.fmt.allocPrint(
        testing.allocator,
        \\local d = "{s}"
        \\local dir = makac.fs.open_dir(d)
        \\assert(type(dir) == "userdata")
        \\assert(tostring(dir:path()) == d)
        \\assert(dir:exists("nope") == false)
        \\dir:touch("newfile")
        \\assert(dir:exists("newfile") == true)
        \\dir:make_path("a/b")
        \\assert(makac.fs.stat(d .. "/a/b").type == "dir")
        \\local sub = dir:open_dir("a")
        \\assert(tostring(sub:path()) == d .. "/a")
        \\assert(tostring(sub:parent():path()) == d)
        \\makac.fs.write_file(d .. "/f.txt", "x")
        \\makac.fs.write_file(d .. "/a/g.txt", "y")
        \\local byname = {{}}
        \\for _, e in ipairs(dir:list()) do byname[e.name] = e.type end
        \\assert(byname["a"] == "dir", "list dir type")
        \\assert(byname["f.txt"] == "file", "list file type")
        \\-- walk is a generic-for iterator over everything below
        \\local seen, count = {{}}, 0
        \\for entry in dir:walk() do count = count + 1; seen[tostring(entry)] = true end
        \\assert(count >= 4)
        \\assert(seen["f.txt"] or seen[d .. "/f.txt"])
        \\assert(seen["a/g.txt"] or seen[d .. "/a/g.txt"])
        \\-- remove is recursive
        \\dir:remove("a")
        \\assert(makac.fs.stat(d .. "/a") == nil)
        \\-- sub validation
        \\local ok1 = pcall(function() dir:touch("/abs") end)
        \\assert(not ok1)
        \\local ok2 = pcall(function() dir:touch("../up") end)
        \\assert(not ok2)
        \\-- cwd() is a valid Dir
        \\local cwd = makac.fs.cwd()
        \\assert(makac.fs.stat(tostring(cwd:path())).type == "dir")
    ,
        .{root},
    );
    defer testing.allocator.free(src);
    try v.runString(src, "@dir_test");
}

test "makac.fs.open_dir raises unless the path is a directory" {
    const v = try newTestVM();
    defer v.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const src = try std.fmt.allocPrint(
        testing.allocator,
        \\local d = "{s}"
        \\makac.fs.write_file(d .. "/f", "x")
        \\assert(not pcall(makac.fs.open_dir, d .. "/f"))
        \\assert(not pcall(makac.fs.open_dir, d .. "/ghost"))
    ,
        .{root},
    );
    defer testing.allocator.free(src);
    try v.runString(src, "@dir_test");
}
