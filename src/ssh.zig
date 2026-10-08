// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// ssh.zig — OpenSSH config generation and ssh/scp argv assembly for remote
// targets.
//
// Never speaks the SSH protocol itself: it writes an OpenSSH config enabling
// connection multiplexing (ControlMaster/ControlPath/ControlPersist), then
// shells out to the system `ssh` / `scp`, passing the config via `-F`.

const std = @import("std");

pub const GenError = error{
    InvalidArg,
    MkdirFailed,
    WriteFailed,
    OutOfMemory,
};

/// One SSH config option value; formatted the way Go's `%v` verb would.
pub const OptionValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
};

pub const Option = struct {
    key: []const u8,
    value: OptionValue,
};

/// Human-readable description of a config-generation failure.
pub fn genErrorString(e: GenError) []const u8 {
    return switch (e) {
        error.InvalidArg => "invalid argument",
        error.MkdirFailed => "failed to create directory",
        error.WriteFailed => "failed to write config file",
        error.OutOfMemory => "out of memory",
    };
}

// ------------------------------------------------------- name validation ---

/// True when `name` is safe as a target directory name: non-empty, only
/// `[A-Za-z0-9._-]`, and free of path traversal (`.` / any `..`).
pub fn validTargetName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".")) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// True when `key` begins with a lowercase ASCII letter: a qqmgr pseudo-option
/// (`port`, `vm_port`), never written to the config file.
pub fn isPseudoOption(key: []const u8) bool {
    return key.len > 0 and key[0] >= 'a' and key[0] <= 'z';
}

// ---------------------------------------------------------- config emit ---

/// Write `<data_dir>/ssh.conf` (and create `<data_dir>/ssh/`), returning the
/// absolute path of the written file (owned by `allocator`). `global` is
/// emitted before `vm`; both are sorted by key and never contain pseudo-
/// options. The `global` table's relative string `ControlPath` is rewritten to
/// an absolute path inside `<data_dir>/ssh/`.
pub fn generateConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    global: []const Option,
    vm: []const Option,
) GenError![]u8 {
    if (data_dir.len == 0) return error.InvalidArg;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rel = std.fs.path.join(arena, &.{ data_dir, "ssh.conf" }) catch return error.OutOfMemory;
    const abs = absolutePath(io, arena, rel) catch |e| return e;
    const data_dir_abs = std.fs.path.dirname(abs) orelse abs;
    const control_dir = std.fs.path.join(arena, &.{ data_dir_abs, "ssh" }) catch return error.OutOfMemory;

    ensureDir(io, data_dir_abs) catch return error.MkdirFailed;
    ensureDir(io, control_dir) catch return error.MkdirFailed;

    var out: std.ArrayList(u8) = .empty;
    emitTable(arena, &out, global, control_dir, false, true) catch return error.OutOfMemory;
    emitTable(arena, &out, vm, control_dir, true, false) catch return error.OutOfMemory;

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs, .data = out.items }) catch
        return error.WriteFailed;

    return allocator.dupe(u8, abs) catch return error.OutOfMemory;
}

fn lessOption(_: void, a: Option, b: Option) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

fn emitTable(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    table: []const Option,
    control_dir: []const u8,
    skip_lowercase: bool,
    rewrite_control_path: bool,
) error{OutOfMemory}!void {
    const copy = try arena.alloc(Option, table.len);
    @memcpy(copy, table);
    std.mem.sort(Option, copy, {}, lessOption);

    for (copy) |o| {
        if (o.key.len == 0) continue;
        if (skip_lowercase and isPseudoOption(o.key)) continue;
        const line = switch (o.value) {
            .string => |s| blk: {
                if (rewrite_control_path and std.mem.eql(u8, o.key, "ControlPath") and
                    !std.fs.path.isAbsolute(s))
                {
                    const base = std.fs.path.basename(s);
                    const joined = try std.fs.path.join(arena, &.{ control_dir, base });
                    break :blk try std.fmt.allocPrint(arena, "{s} {s}\n", .{ o.key, joined });
                }
                break :blk try std.fmt.allocPrint(arena, "{s} {s}\n", .{ o.key, s });
            },
            .integer => |i| try std.fmt.allocPrint(arena, "{s} {d}\n", .{ o.key, i }),
            .float => |f| try std.fmt.allocPrint(arena, "{s} {d}\n", .{ o.key, f }),
            .boolean => |b| try std.fmt.allocPrint(
                arena,
                "{s} {s}\n",
                .{ o.key, if (b) "true" else "false" },
            ),
        };
        try out.appendSlice(arena, line);
    }
}

fn ensureDir(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, path) catch return error.MkdirFailed;
}

/// `filepath.Abs`: prefix the cwd when relative, then clean. Never touches the
/// filesystem for the target itself, so it works for paths that do not exist.
fn absolutePath(io: std.Io, alloc: std.mem.Allocator, path: []const u8) GenError![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(alloc, &.{path}) catch return error.OutOfMemory;
    }
    const wd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", alloc) catch return error.WriteFailed;
    defer alloc.free(wd);
    return std.fs.path.resolve(alloc, &.{ wd, path }) catch return error.OutOfMemory;
}

// ---------------------------------------------------------- argv assembly --

/// Full `ssh -F <config> -p <port> localhost [command]` argv (owned slice).
pub fn sshArgv(
    alloc: std.mem.Allocator,
    config_path: []const u8,
    port: i32,
    command: []const u8,
) error{OutOfMemory}![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(alloc, "ssh");
    try list.append(alloc, "-F");
    try list.append(alloc, config_path);
    try list.append(alloc, "-p");
    try list.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{port}));
    try list.append(alloc, "localhost");
    if (command.len > 0) try list.append(alloc, command);
    return list.toOwnedSlice(alloc);
}

/// Full `scp -F <config> -P <port> [-r] <local> localhost:<remote>` argv.
pub fn scpPutArgv(
    alloc: std.mem.Allocator,
    config_path: []const u8,
    port: i32,
    local: []const u8,
    remote: []const u8,
    recursive: bool,
) error{OutOfMemory}![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(alloc, "scp");
    try list.append(alloc, "-F");
    try list.append(alloc, config_path);
    try list.append(alloc, "-P");
    try list.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{port}));
    if (recursive) try list.append(alloc, "-r");
    try list.append(alloc, local);
    try list.append(
        alloc,
        try std.fmt.allocPrint(alloc, "localhost:{s}", .{remote}),
    );
    return list.toOwnedSlice(alloc);
}

/// Full `scp -F <config> -P <port> [-r] localhost:<remote> <local>` argv.
pub fn scpGetArgv(
    alloc: std.mem.Allocator,
    config_path: []const u8,
    port: i32,
    remote: []const u8,
    local: []const u8,
    recursive: bool,
) error{OutOfMemory}![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(alloc, "scp");
    try list.append(alloc, "-F");
    try list.append(alloc, config_path);
    try list.append(alloc, "-P");
    try list.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{port}));
    if (recursive) try list.append(alloc, "-r");
    try list.append(
        alloc,
        try std.fmt.allocPrint(alloc, "localhost:{s}", .{remote}),
    );
    try list.append(alloc, local);
    return list.toOwnedSlice(alloc);
}

/// Full `ssh -F <config> -p <port> -O exit localhost` argv — tears down the
/// multiplex master for `close()` (owned slice).
pub fn sshExitArgv(
    alloc: std.mem.Allocator,
    config_path: []const u8,
    port: i32,
) error{OutOfMemory}![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(alloc, "ssh");
    try list.append(alloc, "-F");
    try list.append(alloc, config_path);
    try list.append(alloc, "-p");
    try list.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{port}));
    try list.append(alloc, "-O");
    try list.append(alloc, "exit");
    try list.append(alloc, "localhost");
    return list.toOwnedSlice(alloc);
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

fn joinArgs(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (argv, 0..) |a, i| {
        if (i != 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, a);
    }
    return out.toOwnedSlice(alloc);
}

test "name validation rejects traversal and bad charset" {
    try testing.expect(validTargetName("vm1"));
    try testing.expect(validTargetName("demo.pkg_2-x"));
    try testing.expect(!validTargetName(""));
    try testing.expect(!validTargetName("."));
    try testing.expect(!validTargetName(".."));
    try testing.expect(!validTargetName("a/../b"));
    try testing.expect(!validTargetName("a..b"));
    try testing.expect(!validTargetName("has space"));
    try testing.expect(!validTargetName("colon:name"));
    try testing.expect(!validTargetName("sub/dir"));
}

test "golden: generated config with multiplexing, sorted, ControlPath anchored" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(base);

    const data_dir = try std.fs.path.join(alloc, &.{ base, "vm" });
    defer alloc.free(data_dir);

    const global = [_]Option{
        .{ .key = "ControlMaster", .value = .{ .string = "auto" } },
        .{ .key = "ControlPersist", .value = .{ .string = "10m" } },
        .{ .key = "ControlPath", .value = .{ .string = "ssh/ctrl-%r@%h-%p" } },
        .{ .key = "ServerAliveCountMax", .value = .{ .integer = 3 } },
        .{ .key = "ServerAliveInterval", .value = .{ .integer = 300 } },
        .{ .key = "StrictHostKeyChecking", .value = .{ .string = "no" } },
        .{ .key = "UserKnownHostsFile", .value = .{ .string = "/dev/null" } },
        .{ .key = "User", .value = .{ .string = "root" } },
        .{ .key = "HostKeyAlgorithms", .value = .{ .string = "+ssh-rsa" } },
        .{ .key = "PubkeyAcceptedKeyTypes", .value = .{ .string = "+ssh-rsa" } },
        .{ .key = "UseKeychain", .value = .{ .boolean = true } },
        .{ .key = "FloatOpt", .value = .{ .float = 3.5 } },
    };
    const vm = [_]Option{
        .{ .key = "port", .value = .{ .integer = 22022 } }, // pseudo: skipped
        .{ .key = "vm_port", .value = .{ .integer = 22 } }, // pseudo: skipped
        .{ .key = "IdentityFile", .value = .{ .string = "~/.ssh/id_ed25519" } },
        .{ .key = "User", .value = .{ .string = "vboxuser" } },
    };

    const path = try generateConfig(io, alloc, data_dir, &global, &vm);
    defer alloc.free(path);

    const want = try std.fmt.allocPrint(alloc,
        \\ControlMaster auto
        \\ControlPath {s}/ssh/ctrl-%r@%h-%p
        \\ControlPersist 10m
        \\FloatOpt 3.5
        \\HostKeyAlgorithms +ssh-rsa
        \\PubkeyAcceptedKeyTypes +ssh-rsa
        \\ServerAliveCountMax 3
        \\ServerAliveInterval 300
        \\StrictHostKeyChecking no
        \\UseKeychain true
        \\User root
        \\UserKnownHostsFile /dev/null
        \\IdentityFile ~/.ssh/id_ed25519
        \\User vboxuser
        \\
    , .{data_dir});
    defer alloc.free(want);

    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20));
    defer alloc.free(got);
    try testing.expectEqualStrings(want, got);
    try testing.expect(std.mem.endsWith(u8, path, "/vm/ssh.conf"));
    // the port travels on the command line, never in the config (probed)
    try testing.expect(std.mem.indexOf(u8, got, "Port") == null);
    try testing.expect(std.mem.indexOf(u8, got, "port") == null);

    const ctl = try std.fs.path.join(alloc, &.{ data_dir, "ssh" });
    defer alloc.free(ctl);
    const st = try std.Io.Dir.cwd().statFile(io, ctl, .{ .follow_symlinks = true });
    try testing.expect(st.kind == .directory);
}

test "golden: absolute ControlPath is written verbatim; non-string not rewritten" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(base);

    {
        const data_dir = try std.fs.path.join(alloc, &.{ base, "abc" });
        defer alloc.free(data_dir);
        const global = [_]Option{
            .{ .key = "ControlMaster", .value = .{ .string = "auto" } },
            .{ .key = "ControlPath", .value = .{ .string = "/abs/ctrl-%r@%h-%p" } },
        };
        const path = try generateConfig(io, alloc, data_dir, &global, &.{});
        defer alloc.free(path);
        const got = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20));
        defer alloc.free(got);
        try testing.expectEqualStrings(
            "ControlMaster auto\nControlPath /abs/ctrl-%r@%h-%p\n",
            got,
        );
    }
    {
        const data_dir = try std.fs.path.join(alloc, &.{ base, "num" });
        defer alloc.free(data_dir);
        const global = [_]Option{
            .{ .key = "ControlPath", .value = .{ .integer = 123 } },
        };
        const path = try generateConfig(io, alloc, data_dir, &global, &.{});
        defer alloc.free(path);
        const got = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20));
        defer alloc.free(got);
        try testing.expectEqualStrings("ControlPath 123\n", got);
    }
}

test "generateConfig rejects an empty data_dir" {
    try testing.expectError(
        error.InvalidArg,
        generateConfig(testing.io, testing.allocator, "", &.{}, &.{}),
    );
}

test "golden: ssh argv assembly (interactive and with command)" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    {
        const argv = try sshArgv(a, "/cfg/ssh.conf", 2222, "uname -a");
        const s = try joinArgs(a, argv);
        try testing.expectEqualStrings("ssh -F /cfg/ssh.conf -p 2222 localhost uname -a", s);
    }
    {
        const argv = try sshArgv(a, "/cfg/ssh.conf", 2222, "");
        const s = try joinArgs(a, argv);
        try testing.expectEqualStrings("ssh -F /cfg/ssh.conf -p 2222 localhost", s);
    }
}

test "golden: scp put/get argv assembly and -r placement" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    {
        const argv = try scpPutArgv(a, "/cfg", 2222, "/local/f.txt", "remote.txt", false);
        const s = try joinArgs(a, argv);
        try testing.expectEqualStrings("scp -F /cfg -P 2222 /local/f.txt localhost:remote.txt", s);
    }
    {
        const argv = try scpPutArgv(a, "/cfg", 2222, "/local/dir", "rdir", true);
        const s = try joinArgs(a, argv);
        try testing.expectEqualStrings("scp -F /cfg -P 2222 -r /local/dir localhost:rdir", s);
    }
    {
        const argv = try scpGetArgv(a, "/cfg", 2222, "remote.txt", "/local/out.txt", false);
        const s = try joinArgs(a, argv);
        try testing.expectEqualStrings("scp -F /cfg -P 2222 localhost:remote.txt /local/out.txt", s);
    }
    {
        const argv = try scpGetArgv(a, "/cfg", 2222, "rdir", "/local/outdir", true);
        const s = try joinArgs(a, argv);
        try testing.expectEqualStrings("scp -F /cfg -P 2222 -r localhost:rdir /local/outdir", s);
    }
    {
        const argv = try sshExitArgv(a, "/cfg", 2222);
        const s = try joinArgs(a, argv);
        try testing.expectEqualStrings("ssh -F /cfg -p 2222 -O exit localhost", s);
    }
}
