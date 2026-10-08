// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// spawn.zig — `makac.spawn`: fork a detached long-lived process whose
// lifetime nobody manages (QEMU and friends).
//
//   makac.spawn(argv, { stdout = <path>, stderr = <path>, chdir?, env? }) -> proc
//     proc.pid      -> integer
//     proc:status() -> "running" | { code = }  -- waitpid(WNOHANG); reaps once
//
// Hard rules of detached spawning:
//   * The child calls setsid() after dup2/chdir and before exec, so it leads
//     its OWN session and process group. A child left in makac's group dies
//     with makac (the terminal signals the foreground group). If setsid fails
//     the child writes a refusal notice and exits 125.
//   * stdio goes to FILES, never pipes; stdin is /dev/null.
//   * stdout/stderr are required, string-or-path each.
//   * No :kill, and the object NEVER kills on GC.

const std = @import("std");
const lua = @import("../lua.zig");
const reg = @import("register.zig");
const path = @import("path.zig");
const sp = @import("../subprocess.zig");
const linux = std.os.linux;

const c_alloc = std.heap.c_allocator;

/// Metatable name of the `proc` userdata.
pub const SPAWN_MT: [:0]const u8 = "makac.proc";

/// Userdata payload: the child pid, an owned display label, and the cached
/// reap result. NEVER a kill handle.
const SpawnObject = struct {
    pid: linux.pid_t,
    cmd: []u8,
    reaped: bool,
    code: i32,
};

fn oom(L: *lua.State) noreturn {
    lua.raiseLString(L, "makac.spawn: out of memory");
}

fn raiseFmt(L: *lua.State, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "makac.spawn: error";
    lua.raiseLString(L, msg);
}

fn selfPtr(L: *lua.State) *SpawnObject {
    return @ptrCast(@alignCast(lua.checkUdata(L, 1, SPAWN_MT) orelse unreachable));
}

pub fn registerSpawn(L: *lua.State) void {
    if (lua.newMetatable(L, SPAWN_MT)) {
        lua.pushCFunction(L, spawnIndex);
        lua.setField(L, -2, "__index");
        lua.pushCFunction(L, spawnGc);
        lua.setField(L, -2, "__gc");
        lua.pushCFunction(L, spawnTostring);
        lua.setField(L, -2, "__tostring");
    }
    lua.pop(L, 1); // the metatable
    reg.register(L, "spawn", makacSpawn);
}

// ------------------------------------------------------- metamethods ------

fn spawnIndex(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = selfPtr(L);
    if (lua.typeOf(L, 2) != lua.TSTRING) {
        lua.pushNil(L);
        return 1;
    }
    const key = lua.toLString(L, 2) orelse {
        lua.pushNil(L);
        return 1;
    };
    if (std.mem.eql(u8, key, "pid")) {
        lua.pushInteger(L, self.pid);
    } else if (std.mem.eql(u8, key, "status")) {
        lua.pushCFunction(L, procStatus);
    } else {
        lua.pushNil(L);
    }
    return 1;
}

/// __gc: NEVER kills the child — reaping a still-running child would block
/// anyway; an orphan is inherited and reaped by init once makac exits. The
/// only work here is freeing the owned label.
fn spawnGc(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const p = lua.toUserdata(L, 1) orelse return 0;
    const self: *SpawnObject = @ptrCast(@alignCast(p));
    if (self.cmd.len != 0) c_alloc.free(self.cmd);
    self.cmd = &.{};
    return 0;
}

fn spawnTostring(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = selfPtr(L);
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "makac.proc: pid {d} ({s})", .{ self.pid, self.cmd }) catch {
        lua.pushLString(L, "makac.proc");
        return 1;
    };
    lua.pushLString(L, s);
    return 1;
}

/// proc:status() -> "running" | { code = } — one waitpid(WNOHANG); once the
/// child has exited it is REAPED and the cached result is reported on every
/// later call. A signal termination reports 128+signum (shell convention).
fn procStatus(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = selfPtr(L);
    if (!self.reaped) {
        var status: u32 = 0;
        const rc = linux.waitpid(self.pid, &status, linux.W.NOHANG);
        const e = linux.errno(rc);
        if (e == .SUCCESS and rc == @as(usize, @intCast(self.pid))) {
            self.reaped = true;
            if (linux.W.IFEXITED(status)) {
                self.code = @intCast(linux.W.EXITSTATUS(status));
            } else if (linux.W.IFSIGNALED(status)) {
                self.code = 128 + @as(i32, @intCast(@intFromEnum(linux.W.TERMSIG(status))));
            } else {
                // neither exited nor signaled and WNOHANG matched — only
                // possible with stopped/continued flags we never set
                self.code = -1;
            }
        } else if (e != .SUCCESS) {
            raiseFmt(L, "makac.proc: status: waitpid failed: {s}", .{@tagName(e)});
        }
        // rc == 0: still running
    }
    if (self.reaped) {
        lua.createTable(L, 0, 1);
        lua.pushInteger(L, self.code);
        lua.setField(L, -2, "code");
    } else {
        lua.pushLString(L, "running");
    }
    return 1;
}

// --------------------------------------------------------- option reads ---

/// opts.<field> — string-or-path, required. Returns a copy owned by `arena`.
fn reqPathField(
    L: *lua.State,
    idx: c_int,
    field: [:0]const u8,
    arena: std.mem.Allocator,
) []const u8 {
    _ = lua.getField(L, idx, field);
    defer lua.pop(L, 1);
    const t = lua.typeOf(L, -1);
    if (t != lua.TSTRING and t != lua.TUSERDATA) {
        raiseFmt(L, "makac.spawn: opts.{s} (string or path) is required", .{field});
    }
    const s = path.checkPathString(L, -1); // anchored by the stack slot
    return arena.dupe(u8, s) catch oom(L);
}

/// Optional variant: nil/absent means "no override".
fn optPathField(
    L: *lua.State,
    idx: c_int,
    field: [:0]const u8,
    arena: std.mem.Allocator,
) ?[]const u8 {
    _ = lua.getField(L, idx, field);
    defer lua.pop(L, 1);
    const t = lua.typeOf(L, -1);
    if (t == lua.TNIL) return null;
    if (t != lua.TSTRING and t != lua.TUSERDATA) {
        raiseFmt(L, "makac.spawn: opts.{s} must be a string or path", .{field});
    }
    const s = path.checkPathString(L, -1);
    return arena.dupe(u8, s) catch oom(L);
}

/// opts.env — when present and a table, merge KEY=VALUE overrides onto the
/// process environment (exec's semantics). Returns null when there is no
/// table or the table is empty (inherit the parent environment verbatim).
fn collectEnv(L: *lua.State, arena: std.mem.Allocator) ?[]const []const u8 {
    _ = lua.getField(L, 2, "env"); // [env]
    if (lua.typeOf(L, -1) != lua.TTABLE) {
        lua.pop(L, 1); // whatever 'env' was
        return null;
    }

    var overrides: std.ArrayList([]const u8) = .empty;
    lua.pushNil(L); // [env, nil]
    while (lua.next(L, -2) != 0) { // [env, key, value]
        const k = lua.toLString(L, -2);
        const v = lua.toLString(L, -1);
        if (k != null and v != null) {
            const kv = std.fmt.allocPrint(arena, "{s}={s}", .{ k.?, v.? }) catch oom(L);
            overrides.append(arena, kv) catch oom(L);
        }
        lua.pop(L, 1); // [env, key]
    }
    lua.pop(L, 1); // [env]
    if (overrides.items.len == 0) return null;

    var merged: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        merged.append(arena, arena.dupe(u8, std.mem.span(entry)) catch oom(L)) catch oom(L);
    }
    for (overrides.items) |ov| {
        const eq = std.mem.indexOfScalar(u8, ov, '=') orelse continue; // _merge_env builds K=V
        const prefix = ov[0 .. eq + 1];
        var replaced = false;
        for (merged.items) |*e| {
            if (std.mem.startsWith(u8, e.*, prefix)) {
                e.* = ov;
                replaced = true;
                break;
            }
        }
        if (!replaced) merged.append(arena, ov) catch oom(L);
    }
    return merged.items;
}

/// Resolve `file` against PATH the way execvp does (using `env`'s PATH when
/// provided, else the parent's), so the child can use execve with an explicit
/// environment. Unresolved names are returned unchanged: execve then fails
/// and the child exits 127.
fn resolveExe(
    L: *lua.State,
    arena: std.mem.Allocator,
    file: []const u8,
    env: ?[]const []const u8,
) [:0]const u8 {
    var resolved: []const u8 = file;
    if (sp.findExecutable(arena, file, env)) |p| {
        resolved = p;
    } else |_| {}
    return arena.dupeZ(u8, resolved) catch oom(L);
}

// --------------------------------------------------------------- spawn ----

fn makacSpawn(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    lua.checkType(L, 1, lua.TTABLE);
    lua.checkType(L, 2, lua.TTABLE);

    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // argv — array of strings, non-empty (same discipline as makac.exec).
    var argv: std.ArrayList([]const u8) = .empty;
    const n = lua.rawLen(L, 1);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        _ = lua.rawGetI(L, 1, @intCast(i));
        const s = lua.toLString(L, -1) orelse {
            lua.pop(L, 1);
            raiseFmt(L, "makac.spawn: argv[{d}] must be a string", .{i});
        };
        argv.append(arena, arena.dupe(u8, s) catch oom(L)) catch oom(L);
        lua.pop(L, 1);
    }
    if (argv.items.len == 0) lua.raiseLString(L, "makac.spawn: argv must not be empty");

    const stdout = reqPathField(L, 2, "stdout", arena);
    const stderr = reqPathField(L, 2, "stderr", arena);
    const chdir = optPathField(L, 2, "chdir", arena);
    const env = collectEnv(L, arena);

    // Marshal everything NOW, in the parent: after fork the child does
    // syscalls only (no allocation — the copied allocator state is not to be
    // trusted at an exec boundary).
    const exe_z = resolveExe(L, arena, argv.items[0], env);

    const argv_z = arena.alloc(?[*:0]const u8, argv.items.len + 1) catch oom(L);
    for (argv.items, 0..) |a, j| argv_z[j] = (arena.dupeZ(u8, a) catch oom(L)).ptr;
    argv_z[argv.items.len] = null;
    const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv_z.ptr);

    var envp_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    if (env) |entries| {
        const envp_z = arena.alloc(?[*:0]const u8, entries.len + 1) catch oom(L);
        for (entries, 0..) |e, j| envp_z[j] = (arena.dupeZ(u8, e) catch oom(L)).ptr;
        envp_z[entries.len] = null;
        envp_ptr = @ptrCast(envp_z.ptr);
    }

    const chdir_z: ?[:0]const u8 = if (chdir) |c|
        (arena.dupeZ(u8, c) catch oom(L))
    else
        null;

    // stdio FILES (the one hard rule: never pipes). Open failures raise;
    // L_error longjmps, so every later failure path closes explicitly.
    const stdout_z = arena.dupeZ(u8, stdout) catch oom(L);
    const stderr_z = arena.dupeZ(u8, stderr) catch oom(L);
    const open_flags = linux.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };

    const out_fd = blk: {
        const rc = linux.open(stdout_z.ptr, open_flags, 0o644);
        const e = linux.errno(rc);
        if (e != .SUCCESS) {
            raiseFmt(L, "makac.spawn: cannot open stdout '{s}': {s}", .{ stdout, @tagName(e) });
        }
        break :blk @as(linux.fd_t, @intCast(rc));
    };
    const err_fd = blk: {
        const rc = linux.open(stderr_z.ptr, open_flags, 0o644);
        const e = linux.errno(rc);
        if (e != .SUCCESS) {
            _ = linux.close(out_fd);
            raiseFmt(L, "makac.spawn: cannot open stderr '{s}': {s}", .{ stderr, @tagName(e) });
        }
        break :blk @as(linux.fd_t, @intCast(rc));
    };
    const in_fd = blk: {
        const rc = linux.open("/dev/null", .{}, 0);
        const e = linux.errno(rc);
        if (e != .SUCCESS) {
            _ = linux.close(out_fd);
            _ = linux.close(err_fd);
            raiseFmt(L, "makac.spawn: cannot open /dev/null: {s}", .{@tagName(e)});
        }
        break :blk @as(linux.fd_t, @intCast(rc));
    };

    const fork_rc = linux.fork();
    const fork_err = linux.errno(fork_rc);
    if (fork_err != .SUCCESS) {
        _ = linux.close(in_fd);
        _ = linux.close(out_fd);
        _ = linux.close(err_fd);
        raiseFmt(L, "makac.spawn: fork failed: {s}", .{@tagName(fork_err)});
    }
    const pid: linux.pid_t = @intCast(fork_rc);

    if (pid == 0) {
        // CHILD — no allocation, no Lua, syscalls only. Wire the files onto
        // 0/1/2, close every inherited fd (QMP sockets, SSH control sockets,
        // capture pipes), chdir if asked, detach, exec. Exec failure exits
        // 127; chdir failure 126; setsid failure 125.
        _ = linux.dup2(in_fd, 0);
        _ = linux.dup2(out_fd, 1);
        _ = linux.dup2(err_fd, 2);
        sp.closeFdsAbove(-1);
        if (chdir_z) |c| {
            if (linux.errno(linux.chdir(c.ptr)) != .SUCCESS) linux.exit_group(126);
        }
        if (linux.errno(linux.setsid()) != .SUCCESS) {
            const msg = "makac.spawn: setsid failed; refusing to run attached to a controlling terminal\n";
            _ = linux.write(2, msg.ptr, msg.len);
            linux.exit_group(125);
        }
        _ = linux.execve(exe_z.ptr, argv_ptr, envp_ptr);
        linux.exit_group(127);
    }

    // PARENT — the child holds its own copies; drop ours.
    _ = linux.close(in_fd);
    _ = linux.close(out_fd);
    _ = linux.close(err_fd);

    const label = std.mem.join(arena, " ", argv.items) catch oom(L);
    const self: *SpawnObject = lua.newUserdata(L, SpawnObject);
    self.* = .{
        .pid = pid,
        .cmd = c_alloc.dupe(u8, label) catch oom(L),
        .reaped = false,
        .code = 0,
    };
    lua.setMetatable(L, SPAWN_MT);
    return 1;
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

fn sleepMs(ms: u64) void {
    var req = linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = linux.nanosleep(&req, null);
}

fn getGlobalInt(L: *lua.State, name: [:0]const u8) i64 {
    _ = lua.getGlobal(L, name);
    const v = lua.toInteger(L, -1);
    lua.pop(L, 1);
    return v;
}

fn newTestVM() !*@import("../vm.zig").VM {
    return @import("../vm.zig").VM.new(testing.allocator, testing.io, .{});
}

test "spawn registration + bad args raise" {
    const vm = try newTestVM();
    defer vm.deinit();
    try vm.runString(
        \\assert(type(makac.spawn) == "function")
        \\local bad = {
        \\  function() makac.spawn() end,
        \\  function() makac.spawn("ls", { stdout = "a", stderr = "b" }) end,
        \\  function() makac.spawn({}, { stdout = "a", stderr = "b" }) end,
        \\  function() makac.spawn({{}}, { stdout = "a", stderr = "b" }) end,
        \\  function() makac.spawn({"true"}, { stderr = "b" }) end,
        \\  function() makac.spawn({"true"}, { stdout = "a" }) end,
        \\  function() makac.spawn({"true"}, { stdout = 42, stderr = "b" }) end,
        \\  function() makac.spawn({"true"}) end,
        \\}
        \\for _, f in ipairs(bad) do
        \\  local ok, err = pcall(f)
        \\  assert(not ok, "must raise")
        \\  assert(type(err) == "string" and #err > 0, "raise must carry a message")
        \\end
    , "@spawn_bad_args");
}

test "spawn lifecycle: files, status caching, missing program exits 127" {
    const vm = try newTestVM();
    defer vm.deinit();
    try vm.runString(
        \\local fs = makac.fs
        \\local d = tostring(fs.mktemp_dir("makac_spawn_life"))
        \\local p = makac.spawn(
        \\  {"sh", "-c", "echo OUTLINE; echo ELINE >&2"},
        \\  { stdout = d .. "/out", stderr = d .. "/err" })
        \\assert(type(p) == "userdata")
        \\assert(type(p.pid) == "number" and p.pid > 0)
        \\assert(tostring(p):match("^makac%.proc"))
        \\local st
        \\for _ = 1, 2000 do
        \\  st = p:status()
        \\  if st ~= "running" then break end
        \\  makac.time.sleep(10 * makac.time.ns_per_ms)
        \\end
        \\assert(st ~= "running", "child must exit")
        \\assert(st.code == 0)
        \\assert(p:status().code == 0, "cached thereafter")
        \\assert(fs.read_file(d .. "/out") == "OUTLINE\n")
        \\assert(fs.read_file(d .. "/err") == "ELINE\n")
        \\-- a missing program: spawn succeeds, the child exits 127
        \\local m = makac.spawn(
        \\  {"definitely-not-a-real-program-makac-test"},
        \\  { stdout = d .. "/m.out", stderr = d .. "/m.err" })
        \\for _ = 1, 2000 do
        \\  st = m:status()
        \\  if st ~= "running" then break end
        \\  makac.time.sleep(10 * makac.time.ns_per_ms)
        \\end
        \\assert(st ~= "running" and st.code == 127)
    , "@spawn_life");
}

test "spawn child detaches into its own session" {
    const vm = try newTestVM();
    defer vm.deinit();
    try vm.runString(
        \\local d = tostring(makac.fs.mktemp_dir("makac_spawn_session"))
        \\local p = makac.spawn({"sleep", "30"}, { stdout = d .. "/out", stderr = d .. "/err" })
        \\g_pid = p.pid
    , "@spawn_session");

    const pid_i = getGlobalInt(vm.L, "g_pid");
    try testing.expect(pid_i > 1);
    const pid: linux.pid_t = @intCast(pid_i);

    // Detaching is asynchronous: fork() returns in the parent BEFORE the child
    // reaches setsid(), so reading the ids straight away races the child.
    // Poll against a bounded deadline.
    var child_pgrp: linux.pid_t = 0;
    var child_sid: linux.pid_t = 0;
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        child_pgrp = @intCast(linux.getpgid(pid));
        child_sid = @intCast(linux.getsid(pid));
        if (child_pgrp == pid and child_sid == pid) break;
        sleepMs(10);
    }

    const our_pgrp: linux.pid_t = @intCast(linux.getpgid(0));
    try testing.expectEqual(pid, child_pgrp);
    try testing.expectEqual(pid, child_sid);
    try testing.expect(child_pgrp != our_pgrp);

    // No :kill by design — stop it with a plain signal and reap it.
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.kill(pid, .TERM)));
    var status: u32 = 0;
    _ = linux.waitpid(pid, &status, 0);
}
