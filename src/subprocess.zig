// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// subprocess.zig — the syscall-dense process core, independent of Lua.
//
// Linux-first (raw syscalls via std.os.linux) with a poll-based read loop
// and a deadline — never a busy-spin loop.
//
// The child performs syscalls only between fork and exec (no allocation, no
// runtime), closes every inherited fd above 2 except the exec-status pipe,
// and reports a pre-exec failure to the parent as one errno byte.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const E = linux.E;

comptime {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos)
        @compileError("subprocess.zig is Linux-first; add a POSIX branch here");
}

pub const LineCallback = *const fn (ctx: ?*anyopaque, stream: []const u8, line: []const u8) bool;

pub const Options = struct {
    /// Child's working directory; "" inherits makac's.
    working_dir: []const u8 = "",
    /// When non-null, the child's WHOLE environment (and its PATH= entry is
    /// what an unqualified argv[0] resolves against). null inherits ours.
    env: ?[]const []const u8 = null,
    /// When present and non-empty, written to the child's stdin, then closed.
    stdin_data: ?[]const u8 = null,
    /// When set (and no stdin_data), becomes the child's fd 0.
    stdin_fd: ?linux.fd_t = null,

    /// Capture wiring. When false and the matching *_fd is unset, the pipe
    /// is still created but drained/discarded so a chatty child cannot block.
    capture_stdout: bool = true,
    capture_stderr: bool = true,
    /// When set (and not capturing), the child's fd 1 IS this file.
    stdout_fd: ?linux.fd_t = null,
    stderr_fd: ?linux.fd_t = null,

    /// stderr shares stdout's descriptor: one stream, true interleaving
    /// (the shell's `2>&1`). Result.stderr is then empty.
    join_stderr: bool = false,

    /// > 0 = armed. On expiry the child's process group gets SIGTERM, then a
    /// grace period, then SIGKILL; Result.timed_out is set.
    timeout_s: f64 = 0,
    /// Grace between SIGTERM and SIGKILL. Exposed so tests can shorten it;
    /// the binding never sets it.
    grace_s: f64 = 1.0,

    on_line: ?LineCallback = null,
    on_line_ctx: ?*anyopaque = null,

    /// Owns the returned stdout/stderr buffers.
    allocator: std.mem.Allocator,
};

pub const Result = struct {
    /// Exited: the exit status. Signaled: the signal number. Otherwise -1.
    code: i32,
    stdout: []u8,
    stderr: []u8,
    timed_out: bool,
    callback_aborted: bool,
};

pub const SpawnError = error{
    EmptyArgv,
    FileNotFound,
    AccessDenied,
    InvalidExecutable,
    ForkFailed,
    PipeFailed,
    WaitFailed,
    OutOfMemory,
    Unexpected,
};

/// Human-readable message for a spawn failure (used by the Lua binding).
pub fn errorString(e: SpawnError) []const u8 {
    return switch (e) {
        error.EmptyArgv => "argv must not be empty",
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.InvalidExecutable => "Exec format error",
        error.ForkFailed => "fork failed",
        error.PipeFailed => "pipe failed",
        error.WaitFailed => "wait failed",
        error.OutOfMemory => "out of memory",
        error.Unexpected => "unexpected error",
    };
}

fn mapErrno(e: E) SpawnError {
    return switch (e) {
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .NOEXEC => error.InvalidExecutable,
        .NOMEM => error.OutOfMemory,
        else => error.Unexpected,
    };
}

// -------------------------------------------------------- PATH lookup ------

fn statMode(path_z: [*:0]const u8) ?u16 {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path_z, 0, .{ .TYPE = true, .MODE = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return stx.mode;
}

fn acceptable(mode: u16) bool {
    const m: linux.mode_t = mode;
    return linux.S.ISREG(m) and (m & linux.S.IXUSR) != 0;
}

fn parentPath() []const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const s = std.mem.span(entry);
        if (std.mem.startsWith(u8, s, "PATH=")) return s[5..];
    }
    return "";
}

/// Locate an executable and return its path (owned by `allocator`).
///
/// A `file` containing '/' is a path literal: a regular file with the
/// user-execute bit is accepted; a present-but-unacceptable one is
/// AccessDenied (shell 126); a missing one is FileNotFound (127). A bare
/// name is resolved against `env`'s PATH= (when non-null), else the parent's
/// PATH; no acceptable candidate is FileNotFound.
pub fn findExecutable(
    allocator: std.mem.Allocator,
    file: []const u8,
    env: ?[]const []const u8,
) SpawnError![]u8 {
    if (file.len == 0) return error.FileNotFound;

    const file_z = try allocator.dupeZ(u8, file);
    defer allocator.free(file_z);

    if (std.mem.indexOfScalar(u8, file, '/') != null) {
        const mode = statMode(file_z) orelse return error.FileNotFound;
        if (!acceptable(mode)) return error.AccessDenied;
        return try allocator.dupe(u8, file);
    }

    var path: []const u8 = "";
    if (env) |entries| {
        for (entries) |entry| {
            if (std.mem.startsWith(u8, entry, "PATH=")) {
                path = entry[5..];
                break;
            }
        }
    }
    if (path.len == 0) path = parentPath();
    if (path.len == 0) return error.FileNotFound;

    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ part, file });
        errdefer allocator.free(candidate);
        const cand_z = try allocator.dupeZ(u8, candidate);
        defer allocator.free(cand_z);
        if (statMode(cand_z)) |mode| {
            if (acceptable(mode)) return candidate;
        }
        allocator.free(candidate);
    }
    return error.FileNotFound;
}

// --------------------------------------------------------- child fds -------

/// Close every fd above 2 except `keep` (negative = keep nothing). Runs in
/// the child between fork and exec. Linux takes the close_range(2) fast path
/// (split around `keep`); a kernel without the syscall falls back to the
/// close(2) walk. Public so makac.spawn's detached child can reuse it.
pub fn closeFdsAbove(keep: linux.fd_t) void {
    if (builtin.os.tag == .linux) {
        const no_flags = linux.CLOSE_RANGE{ .UNSHARE = false, .CLOEXEC = false };
        if (keep > 2) _ = linux.close_range(3, keep - 1, no_flags);
        const first: linux.fd_t = if (keep > 2) keep + 1 else 3;
        const rc = linux.close_range(first, -1, no_flags);
        if (linux.errno(rc) != .NOSYS) return;
    }
    closeFdsLoop(keep);
}

fn closeFdsLoop(keep: linux.fd_t) void {
    var limit: usize = 1024;
    if (std.posix.getrlimit(.NOFILE)) |rl| {
        const cur = rl.cur;
        if (cur > 0 and cur != std.math.maxInt(std.posix.rlim_t)) {
            limit = @intCast(@min(cur, 1 << 20));
        }
    } else |_| {}
    var fd: linux.fd_t = 3;
    while (fd < limit) : (fd += 1) {
        if (fd == keep) continue;
        _ = linux.close(fd);
    }
}

fn childFail(w: linux.fd_t, e: E) noreturn {
    const b = [1]u8{@truncate(@as(u16, @intFromEnum(e)))};
    _ = linux.write(w, &b, 1);
    linux.exit_group(127);
}

fn closeFd(fd: linux.fd_t) void {
    if (fd != -1) _ = linux.close(fd);
}

fn pipe2(fds: *[2]linux.fd_t, cloexec: bool) SpawnError!void {
    const flags: linux.O = if (cloexec) .{ .CLOEXEC = true } else .{};
    if (linux.errno(linux.pipe2(fds, flags)) != .SUCCESS) return error.PipeFailed;
}

fn nowNanos() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn killTarget(pid: linux.pid_t, group: bool, sig: linux.SIG) void {
    const target: linux.pid_t = if (group) -pid else pid;
    _ = linux.kill(target, sig);
}

fn waitPid(pid: linux.pid_t, status: *u32) SpawnError!void {
    while (true) {
        const rc = linux.waitpid(pid, status, 0);
        const e = linux.errno(rc);
        if (e == .SUCCESS) return;
        if (e == .INTR) continue;
        return error.WaitFailed;
    }
}

// -------------------------------------------------------- line feeding -----

const Feeder = struct {
    cb: ?LineCallback,
    ctx: ?*anyopaque,
    stopped: bool = false,
};

fn feedLines(
    allocator: std.mem.Allocator,
    acc: *std.ArrayList(u8),
    chunk: []const u8,
    stream: []const u8,
    feeder: *Feeder,
) SpawnError!void {
    if (feeder.cb == null or feeder.stopped) return;
    try acc.appendSlice(allocator, chunk);
    var start: usize = 0;
    var i: usize = 0;
    while (i < acc.items.len) : (i += 1) {
        if (acc.items[i] != '\n') continue;
        if (!feeder.cb.?(feeder.ctx, stream, acc.items[start..i])) {
            feeder.stopped = true;
            acc.clearRetainingCapacity();
            return;
        }
        start = i + 1;
    }
    if (start > 0) {
        const remaining = acc.items.len - start;
        std.mem.copyForwards(u8, acc.items[0..remaining], acc.items[start..]);
        acc.shrinkRetainingCapacity(remaining);
    }
}

fn flushLine(
    acc: *std.ArrayList(u8),
    stream: []const u8,
    feeder: *Feeder,
) void {
    if (feeder.cb == null or feeder.stopped or acc.items.len == 0) return;
    if (!feeder.cb.?(feeder.ctx, stream, acc.items)) feeder.stopped = true;
    acc.clearRetainingCapacity();
}

fn readOne(
    allocator: std.mem.Allocator,
    fd: linux.fd_t,
    out_buf: *std.ArrayList(u8),
    line_buf: *std.ArrayList(u8),
    stream: []const u8,
    readbuf: []u8,
    feeder: *Feeder,
    keep: bool,
) SpawnError!bool {
    const rc = linux.read(fd, readbuf.ptr, readbuf.len);
    const e = linux.errno(rc);
    if (e == .INTR or e == .AGAIN) return false;
    if (e != .SUCCESS) return error.Unexpected;
    if (rc == 0) {
        // EOF
        flushLine(line_buf, stream, feeder);
        return true;
    }
    if (keep) {
        const data = readbuf[0..rc];
        try out_buf.appendSlice(allocator, data);
        try feedLines(allocator, line_buf, data, stream, feeder);
    }
    return false;
}

// ------------------------------------------------------------------ Run ----

pub fn run(argv: []const []const u8, opts: Options) SpawnError!Result {
    if (argv.len == 0 or argv[0].len == 0) return error.EmptyArgv;

    const allocator = opts.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const capture_out = opts.capture_stdout;
    const capture_err = opts.capture_stderr and !opts.join_stderr;
    const group = opts.timeout_s > 0 or opts.on_line != null;

    const exe = try findExecutable(arena, argv[0], opts.env);
    const exe_z = try arena.dupeZ(u8, exe);

    const argv_z = try arena.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |a, i| argv_z[i] = (try arena.dupeZ(u8, a)).ptr;
    argv_z[argv.len] = null;
    const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv_z.ptr);

    var envp_ptr: [*:null]const ?[*:0]const u8 = undefined;
    if (opts.env) |env| {
        const envp_z = try arena.alloc(?[*:0]const u8, env.len + 1);
        for (env, 0..) |e, i| envp_z[i] = (try arena.dupeZ(u8, e)).ptr;
        envp_z[env.len] = null;
        envp_ptr = @ptrCast(envp_z.ptr);
    } else {
        envp_ptr = @ptrCast(std.c.environ);
    }

    const cwd_z: ?[:0]u8 = if (opts.working_dir.len > 0)
        try arena.dupeZ(u8, opts.working_dir)
    else
        null;

    // ---- fd wiring -------------------------------------------------------
    var child_out: linux.fd_t = -1;
    var stdout_r: linux.fd_t = -1;
    if (opts.stdout_fd) |fd| {
        if (!capture_out) child_out = fd;
    }
    if (child_out == -1) {
        var p: [2]linux.fd_t = undefined;
        try pipe2(&p, false);
        stdout_r = p[0];
        child_out = p[1];
    }
    defer closeFd(stdout_r);

    var child_err: linux.fd_t = -1;
    var stderr_r: linux.fd_t = -1;
    if (opts.join_stderr) {
        child_err = child_out;
    } else if (opts.stderr_fd) |fd| {
        if (!capture_err) child_err = fd;
    }
    if (child_err == -1) {
        var p: [2]linux.fd_t = undefined;
        try pipe2(&p, false);
        stderr_r = p[0];
        child_err = p[1];
    }
    defer closeFd(stderr_r);

    var child_in: linux.fd_t = -1;
    var stdin_r: linux.fd_t = -1;
    var stdin_w: linux.fd_t = -1;
    if (opts.stdin_data) |data| {
        if (data.len > 0) {
            var p: [2]linux.fd_t = undefined;
            try pipe2(&p, false);
            stdin_r = p[0];
            stdin_w = p[1];
            child_in = stdin_r;
        }
    }
    if (child_in == -1) {
        if (opts.stdin_fd) |fd| child_in = fd;
    }
    defer closeFd(stdin_r);
    defer closeFd(stdin_w);

    // Exec-status pipe: FD_CLOEXEC on the write end makes a successful exec
    // close it, so the parent's read returns EOF exactly when the child runs.
    var status: [2]linux.fd_t = undefined;
    try pipe2(&status, true);
    var status_r = status[0];
    var status_w: linux.fd_t = status[1];
    defer closeFd(status_r);
    defer closeFd(status_w);

    // ---- fork ------------------------------------------------------------
    const fork_rc = linux.fork();
    const fork_err = linux.errno(fork_rc);
    if (fork_err != .SUCCESS) return error.ForkFailed;
    const pid: linux.pid_t = @intCast(fork_rc);

    if (pid == 0) {
        // CHILD — syscalls only.
        if (group) {
            const rc = linux.setpgid(0, 0);
            const e = linux.errno(rc);
            if (e != .SUCCESS) childFail(status_w, e);
        }

        var fd_in = child_in;
        if (fd_in == -1) {
            const rc = linux.open("/dev/null", .{}, 0);
            const e = linux.errno(rc);
            if (e != .SUCCESS) childFail(status_w, e);
            fd_in = @intCast(rc);
        }
        {
            const rc = linux.dup2(fd_in, 0);
            const e = linux.errno(rc);
            if (e != .SUCCESS) childFail(status_w, e);
        }
        {
            const rc = linux.dup2(child_out, 1);
            const e = linux.errno(rc);
            if (e != .SUCCESS) childFail(status_w, e);
        }
        {
            const rc = linux.dup2(child_err, 2);
            const e = linux.errno(rc);
            if (e != .SUCCESS) childFail(status_w, e);
        }

        // The status pipe must sit above the stdio slots to survive the close.
        if (status_w < 3) linux.exit_group(127);
        closeFdsAbove(status_w);

        if (cwd_z) |cwd| {
            const rc = linux.chdir(cwd.ptr);
            const e = linux.errno(rc);
            if (e != .SUCCESS) childFail(status_w, e);
        }

        const exec_rc = linux.execve(exe_z.ptr, argv_ptr, envp_ptr);
        childFail(status_w, linux.errno(exec_rc));
    }

    // ---- parent: drop the child's copies so EOF is observable ------------
    _ = linux.close(status_w);
    status_w = -1;
    if (stdout_r != -1) {
        _ = linux.close(child_out);
        child_out = -1;
    }
    if (stderr_r != -1) {
        _ = linux.close(child_err);
        child_err = -1;
    }
    if (stdin_r != -1) {
        _ = linux.close(stdin_r);
        stdin_r = -1;
    }

    // Close the setpgid race: adopt the child into its own group if it has
    // not done so itself (EACCES = the child got there first).
    if (group) _ = linux.setpgid(pid, pid);

    // Blocking wait for the exec outcome.
    var exec_byte: [1]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const rc = linux.read(status_r, &exec_byte, 1);
        const e = linux.errno(rc);
        if (e == .SUCCESS) {
            n = rc;
            break;
        }
        if (e == .INTR) continue;
        n = 0;
        break;
    }
    if (n == 1) {
        var wstatus: u32 = 0;
        waitPid(pid, &wstatus) catch {};
        _ = linux.close(status_r);
        status_r = -1;
        return mapErrno(@enumFromInt(exec_byte[0]));
    }

    // Feed stdin, then close so the child sees EOF.
    if (opts.stdin_data) |data| {
        if (data.len > 0) {
            var rest = data;
            while (rest.len > 0) {
                const rc = linux.write(stdin_w, rest.ptr, rest.len);
                const e = linux.errno(rc);
                if (e == .SUCCESS) {
                    rest = rest[rc..];
                } else if (e == .INTR) {
                    continue;
                } else break;
            }
            _ = linux.close(stdin_w);
            stdin_w = -1;
        }
    }

    // ---- read loop (poll + deadline, no busy-spin) -----------------------
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(allocator);
    var out_line: std.ArrayList(u8) = .empty;
    defer out_line.deinit(allocator);
    var err_line: std.ArrayList(u8) = .empty;
    defer err_line.deinit(allocator);

    var feeder = Feeder{ .cb = opts.on_line, .ctx = opts.on_line_ctx };
    var readbuf: [4096]u8 = undefined;
    var stdout_done = stdout_r == -1;
    var stderr_done = stderr_r == -1;
    var timed = opts.timeout_s > 0;
    var timed_out = false;
    var callback_aborted = false;
    var deadline = nowNanos() + @as(i128, @intFromFloat(opts.timeout_s * 1e9));
    var escalation: u8 = 0;

    while (!stdout_done or !stderr_done) {
        var fds: [2]linux.pollfd = undefined;
        var nfds: usize = 0;
        if (!stdout_done) {
            fds[nfds] = .{ .fd = stdout_r, .events = linux.POLL.IN, .revents = 0 };
            nfds += 1;
        }
        if (!stderr_done) {
            fds[nfds] = .{ .fd = stderr_r, .events = linux.POLL.IN, .revents = 0 };
            nfds += 1;
        }

        var ms: i32 = -1;
        if (timed) {
            const rem = deadline - nowNanos();
            ms = if (rem > 0) @intCast(@divTrunc(rem, std.time.ns_per_ms)) else 0;
        }

        const poll_rc = linux.poll(&fds, @intCast(nfds), ms);
        const pe = linux.errno(poll_rc);
        if (pe == .INTR) continue;
        if (pe != .SUCCESS) return error.Unexpected;

        if (poll_rc == 0) {
            switch (escalation) {
                0 => {
                    timed_out = true;
                    killTarget(pid, group, .TERM);
                    deadline = nowNanos() + @as(i128, @intFromFloat(opts.grace_s * 1e9));
                    escalation = 1;
                },
                else => {
                    killTarget(pid, group, .KILL);
                    timed = false;
                    escalation = 2;
                },
            }
            continue;
        }

        var wi: usize = 0;
        if (!stdout_done) {
            const pfd = &fds[0];
            if ((pfd.revents & linux.POLL.IN) != 0) {
                stdout_done = try readOne(
                    allocator,
                    stdout_r,
                    &out_buf,
                    &out_line,
                    "stdout",
                    readbuf[0..],
                    &feeder,
                    capture_out,
                );
            } else if ((pfd.revents & (linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL)) != 0) {
                flushLine(&out_line, "stdout", &feeder);
                stdout_done = true;
            }
            wi = 1;
        }
        if (!stderr_done) {
            const pfd = &fds[wi];
            if ((pfd.revents & linux.POLL.IN) != 0) {
                stderr_done = try readOne(
                    allocator,
                    stderr_r,
                    &err_buf,
                    &err_line,
                    "stderr",
                    readbuf[0..],
                    &feeder,
                    capture_err,
                );
            } else if ((pfd.revents & (linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL)) != 0) {
                flushLine(&err_line, "stderr", &feeder);
                stderr_done = true;
            }
        }

        if (feeder.stopped) {
            callback_aborted = true;
            killTarget(pid, group, .TERM);
            killTarget(pid, group, .KILL);
            timed = false;
        }
    }

    var wstatus: u32 = 0;
    try waitPid(pid, &wstatus);

    var code: i32 = -1;
    if (linux.W.IFEXITED(wstatus)) {
        code = @intCast(linux.W.EXITSTATUS(wstatus));
    } else if (linux.W.IFSIGNALED(wstatus)) {
        code = @intCast(@intFromEnum(linux.W.TERMSIG(wstatus)));
    }

    const stdout_result = try out_buf.toOwnedSlice(allocator);
    errdefer allocator.free(stdout_result);
    const stderr_result = try err_buf.toOwnedSlice(allocator);

    return .{
        .code = code,
        .stdout = stdout_result,
        .stderr = stderr_result,
        .timed_out = timed_out,
        .callback_aborted = callback_aborted,
    };
}

/// kill(pid, 0): true when the process exists (or exists but is not ours).
pub fn pidAlive(pid: linux.pid_t) bool {
    const zero: linux.SIG = @enumFromInt(0);
    const e = linux.errno(linux.kill(pid, zero));
    return e == .SUCCESS or e == .PERM;
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

fn runCaptured(argv: []const []const u8) !Result {
    return run(argv, .{ .allocator = testing.allocator });
}

test "sh -c capture shape; nonzero exit is data" {
    const res = try runCaptured(&.{ "sh", "-c", "printf out; printf err >&2; exit 3" });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);

    try testing.expectEqual(@as(i32, 3), res.code);
    try testing.expectEqualStrings("out", res.stdout);
    try testing.expectEqualStrings("err", res.stderr);
    try testing.expect(!res.timed_out);
    try testing.expect(!res.callback_aborted);
}

test "stdin cat roundtrip" {
    const res = try run(&.{ "cat", "-" }, .{
        .allocator = testing.allocator,
        .stdin_data = "hello-stdin",
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);

    try testing.expectEqual(@as(i32, 0), res.code);
    try testing.expectEqualStrings("hello-stdin", res.stdout);
    try testing.expectEqualStrings("", res.stderr);
}

test "stdout and stderr captured separately" {
    const res = try runCaptured(&.{ "sh", "-c", "printf out; printf err >&2" });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);

    try testing.expectEqual(@as(i32, 0), res.code);
    try testing.expectEqualStrings("out", res.stdout);
    try testing.expectEqualStrings("err", res.stderr);
}

test "join_stderr interleaves into stdout" {
    const res = try run(&.{ "sh", "-c", "printf out; printf err >&2" }, .{
        .allocator = testing.allocator,
        .join_stderr = true,
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);

    try testing.expectEqual(@as(i32, 0), res.code);
    try testing.expectEqualStrings("outerr", res.stdout);
    try testing.expectEqualStrings("", res.stderr);
}

test "join preserves order of a single writer" {
    // A single writer that alternates streams: interleaving must be exact.
    const res = try run(&.{ "sh", "-c", "printf a; printf b >&2; printf c; printf d >&2" }, .{
        .allocator = testing.allocator,
        .join_stderr = true,
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqualStrings("abcd", res.stdout);
}

const LineLog = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]const u8) = .empty,

    fn cb(ctx: ?*anyopaque, stream: []const u8, line: []const u8) bool {
        const self: *LineLog = @ptrCast(@alignCast(ctx.?));
        const s = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ stream, line }) catch return false;
        self.lines.append(self.allocator, s) catch return false;
        return true;
    }

    fn deinit(self: *LineLog) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
    }

    fn expectLines(self: *LineLog, expected: []const []const u8) !void {
        try testing.expectEqual(expected.len, self.lines.items.len);
        for (expected, self.lines.items) |want, got| try testing.expectEqualStrings(want, got);
    }
};

test "on_line sees complete lines in order, full capture preserved" {
    var log = LineLog{ .allocator = testing.allocator };
    defer log.deinit();

    const res = try run(&.{ "sh", "-c", "printf 'a\\nb\\nc\\n'" }, .{
        .allocator = testing.allocator,
        .on_line = LineLog.cb,
        .on_line_ctx = &log,
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);

    try log.expectLines(&.{ "stdout:a", "stdout:b", "stdout:c" });
    try testing.expectEqualStrings("a\nb\nc\n", res.stdout);
}

test "on_line flushes a trailing partial line at EOF" {
    var log = LineLog{ .allocator = testing.allocator };
    defer log.deinit();

    const res = try run(&.{ "sh", "-c", "printf 'a\\nb'" }, .{
        .allocator = testing.allocator,
        .on_line = LineLog.cb,
        .on_line_ctx = &log,
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try log.expectLines(&.{ "stdout:a", "stdout:b" });
}

const AbortLog = struct {
    fn cb(ctx: ?*anyopaque, stream: []const u8, line: []const u8) bool {
        _ = ctx;
        _ = stream;
        _ = line;
        return false;
    }
};

test "on_line returning false aborts the child" {
    const res = try run(&.{ "sh", "-c", "printf 'a\\n'; sleep 5" }, .{
        .allocator = testing.allocator,
        .on_line = AbortLog.cb,
        .timeout_s = 10,
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);

    try testing.expect(res.callback_aborted);
    try testing.expect(!res.timed_out);
}

test "PATH lookup success" {
    const alloc = testing.allocator;
    const p = try findExecutable(alloc, "sh", null);
    defer alloc.free(p);
    try testing.expect(std.fs.path.isAbsolute(p));
    try testing.expect(std.mem.endsWith(u8, p, "/sh"));
}

test "PATH lookup failure is FileNotFound (127)" {
    try testing.expectError(
        error.FileNotFound,
        findExecutable(testing.allocator, "definitely-not-a-real-program-xyz", null),
    );
}

test "path literal that is not executable is AccessDenied (126)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notexec", .data = "#!/bin/sh\necho hi\n" });

    const path = try tmp.dir.realPathFileAlloc(testing.io, "notexec", testing.allocator);
    defer testing.allocator.free(path);

    try testing.expectError(error.AccessDenied, findExecutable(testing.allocator, path, null));
    try testing.expectError(error.AccessDenied, run(&.{path}, .{ .allocator = testing.allocator }));
}

test "timeout kills and reports timed_out" {
    const start = nowNanos();
    const res = try run(&.{ "sleep", "30" }, .{
        .allocator = testing.allocator,
        .timeout_s = 0.2,
        .grace_s = 0.2,
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    const elapsed_ns = nowNanos() - start;

    try testing.expect(res.timed_out);
    try testing.expect(!res.callback_aborted);
    // `sleep` does not trap SIGTERM, so it dies on the first signal.
    try testing.expectEqual(@as(i32, @intCast(@intFromEnum(linux.SIG.TERM))), res.code);
    try testing.expect(elapsed_ns < 5 * std.time.ns_per_s);
}

test "timeout escalates SIGTERM to SIGKILL" {
    // The shell ignores SIGTERM, so only the SIGKILL after the grace ends it;
    // the grandchildren it spawns die with the process group on SIGTERM.
    const start = nowNanos();
    const res = try run(&.{ "sh", "-c", "trap '' TERM; while :; do sleep 5; done" }, .{
        .allocator = testing.allocator,
        .timeout_s = 0.2,
        .grace_s = 0.2,
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    const elapsed_ns = nowNanos() - start;

    try testing.expect(res.timed_out);
    try testing.expectEqual(@as(i32, @intCast(@intFromEnum(linux.SIG.KILL))), res.code);
    try testing.expect(elapsed_ns >= 350 * std.time.ns_per_ms);
    try testing.expect(elapsed_ns < 5 * std.time.ns_per_s);
}

test "chdir sets the working directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);

    const res = try run(&.{ "sh", "-c", "pwd" }, .{
        .allocator = testing.allocator,
        .working_dir = dir,
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);

    try testing.expectEqual(@as(i32, 0), res.code);
    const trimmed = std.mem.trimEnd(u8, res.stdout, "\n");
    try testing.expectEqualStrings(dir, trimmed);
}

test "explicit env replaces the child environment" {
    const res = try run(&.{ "printenv", "MAKAC_UNIT_FOO" }, .{
        .allocator = testing.allocator,
        .env = &.{"MAKAC_UNIT_FOO=unit-value"},
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);

    try testing.expectEqual(@as(i32, 0), res.code);
    try testing.expectEqualStrings("unit-value\n", res.stdout);
}

test "env PATH governs unqualified lookup" {
    // Point PATH at /bin (or the empty PATH fallback) explicitly and run sh.
    const res = try run(&.{ "sh", "-c", "printf ok" }, .{
        .allocator = testing.allocator,
        .env = &.{ "PATH=/usr/bin:/bin", "MAKAC_UNIT_FOO=1" },
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqual(@as(i32, 0), res.code);
    try testing.expectEqualStrings("ok", res.stdout);
}

test "pidAlive reflects process existence" {
    try testing.expect(pidAlive(std.os.linux.getpid()));
    try testing.expect(!pidAlive(0x7fffffff));
}
