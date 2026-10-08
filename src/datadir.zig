// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// datadir.zig — project data-directory resolution and initialization.

const std = @import("std");

/// The project's dependency file lives BESIDE the data directory, in the
/// project root, not inside it (design/packages.md).
pub const PROJECT_FILE_NAME = "makac_project.lua";

/// What a freshly created project file contains: valid Lua plus enough
/// documentation to get started. Kept byte-for-byte in step with the
/// reference.
pub const PROJECT_FILE_TEMPLATE =
    \\-- makac_project.lua — this project's dependency wiring.
    \\--
    \\-- 'inputs' says where each package comes from. The key is a local LABEL for
    \\-- the fetch instruction:
    \\--
    \\--   return {
    \\--     inputs = {
    \\--       qemu = { fetcher = "fetchgit",
    \\--         with = { url = "https://github.com/user/repo.git", rev = "main" } },
    \\--     },
    \\--     packages = { qemu = "qemu" },
    \\--   }
    \\--
    \\-- 'packages' wires an alias to an input label. Aliases are the names workflows
    \\-- and packages use: 'qemu:<action>' in a step's uses field,
    \\-- require("pkgs/qemu/...") in Lua.
    \\--
    \\-- Fetchers in this file: the built-ins ("fetchurl", "fetchgit", "filesystem")
    \\-- or any fetcher provided by another package of this project ('makac fetch'
    \\-- keeps retrying inputs until it cannot make progress). Fetched code is
    \\-- stored content-addressed under .makac/packages/<key>/; stale entries are
    \\-- pruned after each fetch. Packages are fetched explicitly: run 'makac fetch'
    \\-- after editing.
    \\return { inputs = {}, packages = {} }
    \\
;

pub const ResolveError = error{ MkdirFailure, ProjectFileFailure, OutOfMemory };
pub const InitError = error{ MkdirFailure, ProjectFileFailure, OutOfMemory };

/// Result of `resolve`. Both `found` and `created_at_git` carry an owned
/// absolute path to the `.makac` directory; caller frees with the allocator
/// it passed in.
pub const ResolveResult = union(enum) {
    found: []u8,
    created_at_git: []u8,
    none,
};

fn isDir(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return st.kind == .directory;
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return true;
}

fn join(allocator: std.mem.Allocator, parts: []const []const u8) ResolveError![]u8 {
    return std.fs.path.join(allocator, parts) catch error.OutOfMemory;
}

/// The project file belonging to a data directory: its sibling
/// `<project root>/makac_project.lua`.
pub fn projectFilePath(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
) ResolveError![]u8 {
    const root = std.fs.path.dirname(data_dir) orelse ".";
    return join(allocator, &.{ root, PROJECT_FILE_NAME });
}

/// Write PROJECT_FILE_TEMPLATE next to `data_dir` unless a project file
/// already exists. Creating the data directory is what makes a location a
/// makac project, so this always accompanies a creation.
fn ensureProjectFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
) InitError!void {
    const path = projectFilePath(allocator, data_dir) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProjectFileFailure,
    };
    defer allocator.free(path);
    if (exists(io, path)) return;
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = PROJECT_FILE_TEMPLATE,
    }) catch return error.ProjectFileFailure;
}

/// Resolve the project's data directory per design/data_directory.md: walking
/// up from `start_dir`, return the first `.makac` directory found; otherwise,
/// at the first directory containing `.git`, create `.makac` there and return
/// it. If the filesystem root is reached with neither found, return `.none`.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_dir: []const u8,
) ResolveError!ResolveResult {
    var dir = allocator.dupe(u8, start_dir) catch return error.OutOfMemory;
    defer allocator.free(dir);

    // The walk terminates on its own at the filesystem root (`parent == dir`);
    // cap iterations to avoid an infinite loop on a cycle.
    var iter: usize = 0;
    while (iter < 64) : (iter += 1) {
        const makac = join(allocator, &.{ dir, ".makac" }) catch return error.OutOfMemory;
        defer allocator.free(makac);
        if (isDir(io, makac)) {
            return .{ .found = allocator.dupe(u8, makac) catch return error.OutOfMemory };
        }
        const git = join(allocator, &.{ dir, ".git" }) catch return error.OutOfMemory;
        defer allocator.free(git);
        if (isDir(io, git)) {
            std.Io.Dir.cwd().createDirPath(io, makac) catch return error.MkdirFailure;
            try ensureProjectFile(allocator, io, makac);
            return .{ .created_at_git = allocator.dupe(u8, makac) catch return error.OutOfMemory };
        }
        const parent = std.fs.path.dirname(dir) orelse break;
        if (std.mem.eql(u8, parent, dir)) break;
        const next = allocator.dupe(u8, parent) catch return error.OutOfMemory;
        allocator.free(dir);
        dir = next;
    }
    return .none;
}

/// Initialize a data directory per design/cli.md: if `path` ends with
/// `.makac`, create exactly that directory; otherwise create `<path>/.makac`.
/// Creating an already-existing directory is not an error. In both cases the
/// sibling project file is created (if absent).
pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) InitError!void {
    var target: []const u8 = path;
    var owned: ?[]u8 = null;
    if (!std.mem.endsWith(u8, path, ".makac")) {
        const joined = join(allocator, &.{ path, ".makac" }) catch return error.OutOfMemory;
        owned = joined;
        target = joined;
    }
    defer if (owned) |o| allocator.free(o);

    if (!isDir(io, target)) {
        std.Io.Dir.cwd().createDirPath(io, target) catch return error.MkdirFailure;
    }
    try ensureProjectFile(allocator, io, target);
}

// --------------------------------------------------------------- tests -----

/// A throwaway directory under /tmp. We deliberately avoid
/// `std.testing.tmpDir`: it lives under `.zig-cache/` inside this repository,
/// whose `.git` would make the walk-up rule find a project where the tests
/// demand there is none.
const TestDir = struct {
    root: std.Io.Dir,
    name: []u8,
    path: []u8,

    fn deinit(self: *TestDir, io: std.Io, allocator: std.mem.Allocator) void {
        self.root.deleteTree(io, self.name) catch {};
        self.root.close(io);
        allocator.free(self.name);
        allocator.free(self.path);
    }

    fn joinPath(self: *const TestDir, allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.path, rel });
    }
};

fn makeTestDir(io: std.Io, allocator: std.mem.Allocator) !TestDir {
    var seed: [8]u8 = undefined;
    io.random(&seed);
    const name = try std.fmt.allocPrint(
        allocator,
        "makac_datadir_test_{x}",
        .{std.mem.readInt(u64, &seed, .little)},
    );
    errdefer allocator.free(name);

    const root = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    errdefer root.close(io);
    try root.createDirPath(io, name);
    const path = try std.fs.path.join(allocator, &.{ "/tmp", name });
    return .{ .root = root, .name = name, .path = path };
}

fn expectFound(r: ResolveResult, want: []const u8) !void {
    switch (r) {
        .found => |d| {
            defer std.testing.allocator.free(d);
            try std.testing.expectEqualStrings(want, d);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "resolve finds .makac in cwd" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var td = try makeTestDir(io, alloc);
    defer td.deinit(io, alloc);

    const makac = try td.joinPath(alloc, ".makac");
    defer alloc.free(makac);
    try std.Io.Dir.cwd().createDirPath(io, makac);

    const r = try resolve(alloc, io, td.path);
    try expectFound(r, makac);
}

test "resolve finds .makac in an ancestor" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var td = try makeTestDir(io, alloc);
    defer td.deinit(io, alloc);

    const makac = try td.joinPath(alloc, ".makac");
    defer alloc.free(makac);
    try std.Io.Dir.cwd().createDirPath(io, makac);

    const deep = try td.joinPath(alloc, "a/b");
    defer alloc.free(deep);
    try std.Io.Dir.cwd().createDirPath(io, deep);

    const r = try resolve(alloc, io, deep);
    try expectFound(r, makac);
}

test "resolve: .git triggers .makac creation beside it" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var td = try makeTestDir(io, alloc);
    defer td.deinit(io, alloc);

    const git = try td.joinPath(alloc, "repo/.git");
    defer alloc.free(git);
    try std.Io.Dir.cwd().createDirPath(io, git);
    const sub = try td.joinPath(alloc, "repo/sub");
    defer alloc.free(sub);
    try std.Io.Dir.cwd().createDirPath(io, sub);

    const want = try td.joinPath(alloc, "repo/.makac");
    defer alloc.free(want);

    const r = try resolve(alloc, io, sub);
    switch (r) {
        .created_at_git => |d| {
            defer alloc.free(d);
            try std.testing.expectEqualStrings(want, d);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(isDir(io, want));
    const pf = try td.joinPath(alloc, "repo/makac_project.lua");
    defer alloc.free(pf);
    try std.testing.expect(exists(io, pf));
}

test "resolve errors at the filesystem root" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var td = try makeTestDir(io, alloc);
    defer td.deinit(io, alloc);

    const r = try resolve(alloc, io, td.path);
    try std.testing.expect(r == .none);
}

test "init with a plain path creates <path>/.makac" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var td = try makeTestDir(io, alloc);
    defer td.deinit(io, alloc);

    const target = try td.joinPath(alloc, "proj");
    defer alloc.free(target);
    try init(alloc, io, target);

    const makac = try td.joinPath(alloc, "proj/.makac");
    defer alloc.free(makac);
    try std.testing.expect(isDir(io, makac));
    const pf = try td.joinPath(alloc, "proj/makac_project.lua");
    defer alloc.free(pf);
    try std.testing.expect(exists(io, pf));
}

test "init with a .makac suffix uses the path verbatim" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var td = try makeTestDir(io, alloc);
    defer td.deinit(io, alloc);

    const target = try td.joinPath(alloc, "proj/.makac");
    defer alloc.free(target);
    try init(alloc, io, target);

    try std.testing.expect(isDir(io, target));
    const pf = try td.joinPath(alloc, "proj/makac_project.lua");
    defer alloc.free(pf);
    try std.testing.expect(exists(io, pf));
    // no nested `.makac/.makac`
    const nested = try std.fs.path.join(alloc, &.{ target, ".makac" });
    defer alloc.free(nested);
    try std.testing.expect(!isDir(io, nested));
    // project file must live beside, not inside, the data directory
    const inside = try std.fs.path.join(alloc, &.{ target, PROJECT_FILE_NAME });
    defer alloc.free(inside);
    try std.testing.expect(!exists(io, inside));
}

test "init is idempotent and never clobbers the project file" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var td = try makeTestDir(io, alloc);
    defer td.deinit(io, alloc);

    const target = try td.joinPath(alloc, "proj");
    defer alloc.free(target);
    try init(alloc, io, target);

    const pf = try td.joinPath(alloc, "proj/makac_project.lua");
    defer alloc.free(pf);
    try std.testing.expect(exists(io, pf));

    const custom = "return { -- custom\n}\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pf, .data = custom });

    try init(alloc, io, target);
    const makac = try td.joinPath(alloc, "proj/.makac");
    defer alloc.free(makac);
    try std.testing.expect(isDir(io, makac));

    const got = try std.Io.Dir.cwd().readFileAlloc(io, pf, alloc, .limited(1 << 20));
    defer alloc.free(got);
    try std.testing.expectEqualStrings(custom, got);
}
