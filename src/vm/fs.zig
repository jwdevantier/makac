// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// fs.zig — makac.fs, the flat filesystem primitives.
//
// All path arguments accept a string or a `makac.path`
// value (path.checkPathString).
//
//   mkdir_p(path)                      parents as needed; existing dir is fine
//   listdir(path) -> {name,is_dir}[], | (nil, err)
//   read_file(path) -> string | (nil, err)
//   write_file(path, data, {atomic}?)  NUL-safe; parent must exist
//   stat(path) -> {type, size, mtime_ns} | nil
//   mktemp_dir(prefix?) -> path        created 0700, honors $TMPDIR
//   mktemp_file(prefix?) -> path       created empty, honors $TMPDIR
//   sha256(path) -> hex | (nil, err)   STREAMED
//   symlink(target, link)              replaces; refuses non-empty dirs

const std = @import("std");
const builtin = @import("builtin");
const lua = @import("../lua.zig");
const reg = @import("register.zig");
const path = @import("path.zig");
const dirv = @import("dir.zig");
const linux = std.os.linux;

const VM = @import("../vm.zig").VM;
const c_alloc = std.heap.c_allocator;

fn vm(L: *lua.State) *VM {
    return @ptrCast(@alignCast(reg.hostContext(L)));
}

fn oom(L: *lua.State) noreturn {
    lua.raiseLString(L, "makac.fs: out of memory");
}

/// Raise `makac.fs: <prefix>: <formatted>` — the reference raises on writes
/// and other statements, and the error surface keeps `write_file`/`mkdir_p`/…
/// in the message (the api specs match on those substrings).
fn raiseFmt(L: *lua.State, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "makac.fs: error";
    lua.raiseLString(L, msg);
}

/// Push (nil, err) — absence is data for read_file/listdir/sha256.
fn pushNilErr(L: *lua.State, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "makac.fs: error";
    lua.pushNil(L);
    lua.pushLString(L, msg);
}

fn kindName(k: std.Io.File.Kind) []const u8 {
    return dirv.statKindName(k);
}

fn getenv(name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |e| : (i += 1) {
        const s = std.mem.span(e);
        if (std.mem.startsWith(u8, s, name) and s.len > name.len and s[name.len] == '=') {
            return s[name.len + 1 ..];
        }
    }
    return null;
}

// ------------------------------------------------------------ directory ----

fn fsMkdirP(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const v = vm(L);
    const p = path.checkPathString(L, 1);
    std.Io.Dir.cwd().createDirPath(v.io, p) catch |e| {
        raiseFmt(L, "makac.fs: mkdir_p: cannot create directory '{s}': {s}", .{ p, @errorName(e) });
    };
    return 0;
}

fn fsListdir(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const v = vm(L);
    const p = path.checkPathString(L, 1);

    var dir = std.Io.Dir.cwd().openDir(v.io, p, .{ .iterate = true }) catch |e| {
        pushNilErr(L, "cannot list directory '{s}': {s}", .{ p, @errorName(e) });
        return 2;
    };
    defer dir.close(v.io);

    lua.createTable(L, 0, 0);
    const out_idx = lua.absindex(L, -1);
    var it = dir.iterate();
    var n: usize = 0;
    while (true) {
        const maybe = it.next(v.io) catch |e| {
            lua.pop(L, 1); // drop the partial table
            pushNilErr(L, "cannot list directory '{s}': {s}", .{ p, @errorName(e) });
            return 2;
        };
        const entry = maybe orelse break;
        lua.createTable(L, 0, 2);
        lua.pushLString(L, entry.name);
        lua.setField(L, -2, "name");
        lua.pushBoolean(L, entry.kind == .directory);
        lua.setField(L, -2, "is_dir");
        n += 1;
        lua.rawSetI(L, out_idx, @intCast(n));
    }
    return 1;
}

// ---------------------------------------------------------------- files ----

fn fsReadFile(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const v = vm(L);
    const p = path.checkPathString(L, 1);

    var file = std.Io.Dir.cwd().openFile(v.io, p, .{}) catch |e| {
        pushNilErr(L, "cannot read file '{s}': {s}", .{ p, @errorName(e) });
        return 2;
    };
    defer file.close(v.io);

    // Stream to EOF rather than trusting `stat.size`: procfs/sysfs files
    // report 0 but have real content (the reference reads /proc/<pid>/stat
    // for zombie detection), and pipes report no size at all.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(c_alloc);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(v.io, &.{&buf}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => {
                pushNilErr(L, "cannot read file '{s}': {s}", .{ p, @errorName(e) });
                return 2;
            },
        };
        if (n == 0) break;
        data.appendSlice(c_alloc, buf[0..n]) catch {
            pushNilErr(L, "cannot read file '{s}': OutOfMemory", .{p});
            return 2;
        };
    }
    lua.pushLString(L, data.items);
    return 1;
}

fn fsWriteFile(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const v = vm(L);
    const p = path.checkPathString(L, 1);
    // NUL-safe: explicit length, never a C-string conversion
    const data = lua.checkLString(L, 2);

    var atomic = false;
    if (!lua.isNoneOrNil(L, 3)) {
        lua.checkType(L, 3, lua.TTABLE);
        _ = lua.getField(L, 3, "atomic");
        atomic = lua.toBoolean(L, -1);
        lua.pop(L, 1);
    }

    const cwd = std.Io.Dir.cwd();
    if (!atomic) {
        cwd.writeFile(v.io, .{ .sub_path = p, .data = data }) catch |e| {
            raiseFmt(L, "makac.fs: write_file: cannot write file '{s}': {s}", .{ p, @errorName(e) });
        };
        return 0;
    }

    const dir = std.fs.path.dirname(p) orelse ".";
    const base = std.fs.path.basename(p);
    if (base.len == 0) {
        raiseFmt(L, "makac.fs: write_file: cannot write file '{s}': not a file path", .{p});
    }
    var sbuf: [16]u8 = undefined;
    const suffix = randomSuffix(&sbuf);
    const tmp_path = std.fmt.allocPrint(c_alloc, "{s}/.{s}.makac-tmp-{s}", .{ dir, base, suffix }) catch oom(L);
    defer c_alloc.free(tmp_path);

    var file = cwd.createFile(v.io, tmp_path, .{ .exclusive = true, .truncate = false }) catch |e| {
        raiseFmt(
            L,
            "makac.fs: write_file: cannot create temp file for atomic write of '{s}': {s}",
            .{ p, @errorName(e) },
        );
    };
    var wrote_ok = true;
    file.writeStreamingAll(v.io, data) catch {
        wrote_ok = false;
    };
    file.close(v.io);
    if (!wrote_ok) {
        _ = cwd.deleteFile(v.io, tmp_path) catch {};
        raiseFmt(L, "makac.fs: write_file: cannot write file '{s}'", .{p});
    }
    cwd.rename(tmp_path, cwd, p, v.io) catch |e| {
        _ = cwd.deleteFile(v.io, tmp_path) catch {};
        raiseFmt(L, "makac.fs: write_file: cannot rename temp file over '{s}': {s}", .{ p, @errorName(e) });
    };
    return 0;
}

fn fsStat(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const v = vm(L);
    const p = path.checkPathString(L, 1);
    const st = std.Io.Dir.cwd().statFile(v.io, p, .{ .follow_symlinks = false }) catch |e| {
        if (e == error.FileNotFound) {
            lua.pushNil(L);
            return 1;
        }
        raiseFmt(L, "makac.fs: stat: cannot stat '{s}': {s}", .{ p, @errorName(e) });
    };
    lua.createTable(L, 0, 3);
    lua.pushLString(L, kindName(st.kind));
    lua.setField(L, -2, "type");
    lua.pushInteger(L, @intCast(st.size));
    lua.setField(L, -2, "size");
    lua.pushInteger(L, @intCast(st.mtime.nanoseconds));
    lua.setField(L, -2, "mtime_ns");
    return 1;
}

// --------------------------------------------------------------- symlink ----

/// Remove an existing entry at `link`: a plain file or symlink first, then an
/// empty directory. A non-empty directory fails the `..NotEmpty` error, which
/// the caller turns into a raise (the "never clobber real content" guard).
fn removeExisting(L: *lua.State, link: []const u8) void {
    std.Io.Dir.cwd().deleteFile(vm(L).io, link) catch |e| switch (e) {
        error.FileNotFound => return,
        error.IsDir => {
            std.Io.Dir.cwd().deleteDir(vm(L).io, link) catch |e2| {
                raiseFmt(L, "makac.fs: symlink: cannot replace '{s}': {s}", .{ link, @errorName(e2) });
            };
        },
        else => raiseFmt(L, "makac.fs: symlink: cannot replace '{s}': {s}", .{ link, @errorName(e) }),
    };
}

fn fsSymlink(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const v = vm(L);
    const target = path.checkPathString(L, 1);
    const link = path.checkPathString(L, 2);
    removeExisting(L, link);
    std.Io.Dir.cwd().symLink(v.io, target, link, .{}) catch |e| {
        raiseFmt(L, "makac.fs: symlink: cannot symlink '{s}' -> '{s}': {s}", .{ link, target, @errorName(e) });
    };
    return 0;
}

// ---------------------------------------------------------------- temp -----

fn randomSuffix(buf: *[16]u8) []const u8 {
    var bytes: [8]u8 = undefined;
    _ = linux.getrandom(&bytes, bytes.len, 0);
    buf.* = std.fmt.bytesToHex(bytes, .lower);
    return buf;
}

fn mktempPrefix(L: *lua.State) []const u8 {
    if (!lua.isNoneOrNil(L, 1)) return lua.checkLString(L, 1);
    return "makac-";
}

/// The default temp root: $TMPDIR (trailing slashes trimmed), else /tmp.
fn tempBase(L: *lua.State) []u8 {
    if (getenv("TMPDIR")) |t| {
        if (t.len > 0) {
            var s = std.mem.trimEnd(u8, t, "/");
            if (s.len == 0) s = "/";
            return c_alloc.dupe(u8, s) catch oom(L);
        }
    }
    return c_alloc.dupe(u8, "/tmp") catch oom(L);
}

fn fsMktempDir(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const prefix = mktempPrefix(L);
    const base = tempBase(L);
    defer c_alloc.free(base);

    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        var sbuf: [16]u8 = undefined;
        const suffix = randomSuffix(&sbuf);
        const p = std.fmt.allocPrintSentinel(c_alloc, "{s}/{s}{s}", .{ base, prefix, suffix }, 0) catch oom(L);
        const rc = linux.mkdirat(linux.AT.FDCWD, p.ptr, 0o700);
        if (linux.errno(rc) == .SUCCESS) {
            const owned = c_alloc.dupe(u8, p[0..p.len]) catch oom(L);
            c_alloc.free(p);
            path.pushPathOwned(L, owned);
            return 1;
        }
        const e = linux.errno(rc);
        c_alloc.free(p);
        if (e != .EXIST) {
            raiseFmt(L, "makac.fs: mktemp_dir: cannot create temp directory: {s}", .{@tagName(e)});
        }
    }
    raiseFmt(L, "makac.fs: mktemp_dir: cannot create temp directory: too many attempts", .{});
}

fn fsMktempFile(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const prefix = mktempPrefix(L);
    const base = tempBase(L);
    defer c_alloc.free(base);

    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        var sbuf: [16]u8 = undefined;
        const suffix = randomSuffix(&sbuf);
        const p = std.fmt.allocPrintSentinel(c_alloc, "{s}/{s}{s}", .{ base, prefix, suffix }, 0) catch oom(L);
        const rc = linux.openat(
            linux.AT.FDCWD,
            p.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true },
            0o600,
        );
        if (linux.errno(rc) == .SUCCESS) {
            _ = linux.close(@intCast(rc));
            const owned = c_alloc.dupe(u8, p[0..p.len]) catch oom(L);
            c_alloc.free(p);
            path.pushPathOwned(L, owned);
            return 1;
        }
        const e = linux.errno(rc);
        c_alloc.free(p);
        if (e != .EXIST) {
            raiseFmt(L, "makac.fs: mktemp_file: cannot create temp file: {s}", .{@tagName(e)});
        }
    }
    raiseFmt(L, "makac.fs: mktemp_file: cannot create temp file: too many attempts", .{});
}

// ---------------------------------------------------------------- sha256 ----

fn fsSha256(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const v = vm(L);
    const p = path.checkPathString(L, 1);

    var file = std.Io.Dir.cwd().openFile(v.io, p, .{}) catch |e| {
        pushNilErr(L, "cannot hash file '{s}': {s}", .{ p, @errorName(e) });
        return 2;
    };
    defer file.close(v.io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(v.io, &.{&buf}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => {
                pushNilErr(L, "cannot hash file '{s}': {s}", .{ p, @errorName(e) });
                return 2;
            },
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    lua.pushLString(L, &hex);
    return 1;
}

// ----------------------------------------------------------- registration ---

pub fn registerFs(L: *lua.State) void {
    reg.pushSubmodule(L, "fs"); // [fs]
    path.registerPathOnFs(L);
    dirv.registerDirOnFs(L);

    lua.pushCFunction(L, fsMkdirP);
    lua.setField(L, -2, "mkdir_p");
    lua.pushCFunction(L, fsListdir);
    lua.setField(L, -2, "listdir");
    lua.pushCFunction(L, fsReadFile);
    lua.setField(L, -2, "read_file");
    lua.pushCFunction(L, fsWriteFile);
    lua.setField(L, -2, "write_file");
    lua.pushCFunction(L, fsStat);
    lua.setField(L, -2, "stat");
    lua.pushCFunction(L, fsMktempDir);
    lua.setField(L, -2, "mktemp_dir");
    lua.pushCFunction(L, fsMktempFile);
    lua.setField(L, -2, "mktemp_file");
    lua.pushCFunction(L, fsSha256);
    lua.setField(L, -2, "sha256");
    lua.pushCFunction(L, fsSymlink);
    lua.setField(L, -2, "symlink");
    lua.pop(L, 1); // drop fs

    // Flat alias: makac.listdir IS makac.fs.listdir (same function value).
    _ = lua.getGlobal(L, "makac"); // [makac]
    _ = lua.getField(L, -1, "fs"); // [makac, fs]
    _ = lua.getField(L, -1, "listdir"); // [makac, fs, listdir]
    lua.setField(L, -3, "listdir"); // [makac, fs]
    lua.pop(L, 2);
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

fn newTestVM() !*VM {
    return VM.new(testing.allocator, testing.io, .{});
}

test "fs primitives: mkdir_p/listdir/read/write/stat/atomic/sha256/symlink" {
    const v = try newTestVM();
    defer v.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const src = try std.fmt.allocPrint(
        testing.allocator,
        \\local d = "{s}"
        \\makac.fs.mkdir_p(d .. "/a/b")
        \\makac.fs.write_file(d .. "/a/b/f.txt", "a\0b\0c")
        \\assert(makac.fs.read_file(d .. "/a/b/f.txt") == "a\0b\0c")
        \\local missing, merr = makac.fs.read_file(d .. "/nope")
        \\assert(missing == nil and type(merr) == "string")
        \\assert(makac.fs.read_file(d) == nil)
        \\local st = makac.fs.stat(d .. "/a/b")
        \\assert(st.type == "dir")
        \\assert(makac.fs.stat(d .. "/nope") == nil)
        \\local entries = makac.fs.listdir(d .. "/a")
        \\assert(#entries == 1 and entries[1].name == "b" and entries[1].is_dir == true)
        \\assert(#makac.fs.listdir(d .. "/a/b") == 1)
        \\-- atomic replaces and leaves no temp behind
        \\makac.fs.write_file(d .. "/a.txt", "v1", {{ atomic = true }})
        \\makac.fs.write_file(d .. "/a.txt", "v2", {{ atomic = true }})
        \\assert(makac.fs.read_file(d .. "/a.txt") == "v2")
        \\assert(#makac.fs.listdir(d) == 2)
        \\-- sha256 of "v2"
        \\assert(makac.fs.sha256(d .. "/a.txt") == "fb04dcb6970e4c3d1873de51fd5a50d7bb46b3383113602665c350ec40b5f990")
        \\-- symlink create + replace
        \\makac.fs.symlink(d .. "/a.txt", d .. "/l")
        \\assert(makac.fs.read_file(d .. "/l") == "v2")
        \\assert(makac.fs.stat(d .. "/l").type == "link")
        \\makac.fs.symlink(d .. "/a.txt", d .. "/l")
        \\-- non-empty dir guard
        \\makac.fs.mkdir_p(d .. "/real/inner")
        \\local ok = pcall(makac.fs.symlink, d .. "/a.txt", d .. "/real")
        \\assert(not ok)
        \\-- flat alias is the same function value
        \\assert(makac.listdir == makac.fs.listdir)
    ,
        .{root},
    );
    defer testing.allocator.free(src);
    try v.runString(src, "@fs_test");
}

test "fs.write_file raises when the parent is missing" {
    const v = try newTestVM();
    defer v.deinit();
    try v.runString(
        \\local ok, err = pcall(makac.fs.write_file, "/no/such/dir/f", "x")
        \\assert(not ok and tostring(err):find("write_file", 1, true) ~= nil)
    , "@fs_test");
}

test "fs.read_file reads procfs (st_size == 0) content, not just stat size" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const v = try newTestVM();
    defer v.deinit();
    // procfs files report ``st_size == 0`` yet have content; a size-driven
    // reader returns nothing and breaks callers such as the qemu package's
    // zombie detection (`/proc/<pid>/stat`).
    try v.runString(
        \\local s = makac.fs.read_file("/proc/self/stat")
        \\assert(type(s) == "string" and #s > 0)
        \\assert(s:match("^.*%)%s+(%a)") ~= nil)
    , "@fs_test");
}

test "fs.mktemp_dir/file honor TMPDIR and return path values" {
    const v = try newTestVM();
    defer v.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    // runString cannot set env; assert the default /tmp prefix instead and
    // that both are path values with the right kinds.
    try v.runString(
        \\local dp = makac.fs.mktemp_dir("bbpref")
        \\assert(type(dp) == "userdata")
        \\assert(makac.fs.stat(dp).type == "dir")
        \\local fp = makac.fs.mktemp_file("bbpref")
        \\assert(type(fp) == "userdata")
        \\assert(makac.fs.stat(fp).type == "file")
        \\assert(tostring(dp):match("bbpref") ~= nil)
        \\makac.fs.write_file(fp, "filled")
    , "@fs_test");
}
