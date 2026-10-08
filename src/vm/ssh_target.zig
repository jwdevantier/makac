// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// ssh_target.zig — the `makac._ssh_open` binding: the remote (SSH) session
// primitive behind `makac.new_ssh_target` (design/target.md).
//
//   local sess = makac._ssh_open(name, { host, user, port?, options? })
//   sess:run(command, opts?) -> { code, stdout, stderr }
//   sess:put(local_path, remote_path)   -- raises on failure
//   sess:get(remote_path, local_path)   -- raises on failure
//   sess:close()                        -- idempotent
//   sess.name, sess.port                -- introspection
//
// Creating a session writes an OpenSSH config under
// <data_dir>/targets/<name>/ssh.conf (via src/ssh.zig) with
// ControlMaster/ControlPath/ControlPersist set, so the first invocation
// establishes an authenticated master connection and every later run/put/get
// multiplexes through it. NO connection happens at construction — only config
// generation.
//
// Lifecycle: close() tears the control master down (best-effort
// `ssh -O exit`). __gc only frees memory — it never spawns processes; a
// session leaked past close() is backstopped by ControlPersist expiry.
//
// A non-zero exit of `run` is DATA (the returned code); only failure to
// execute at all (no ssh binary, unreachable host) raises. put/get failures
// are errors.

const std = @import("std");
const lua = @import("../lua.zig");
const reg = @import("register.zig");
const ssh = @import("../ssh.zig");
const sp = @import("../subprocess.zig");
const VM = @import("../vm.zig").VM;

pub const MT: [:0]const u8 = "makac.ssh";

/// Userdata payload: the session identity plus the generated config path.
/// Both are owned by `allocator` and freed by `__gc`.
const SshSession = struct {
    name: []u8,
    config_path: []u8,
    port: i32,
    closed: bool,
    allocator: std.mem.Allocator,
};

fn host(L: *lua.State) *VM {
    return @ptrCast(@alignCast(reg.hostContext(L)));
}

pub fn registerSshTarget(L: *lua.State) void {
    if (lua.newMetatable(L, MT)) {
        lua.pushCFunction(L, sshIndex);
        lua.setField(L, -2, "__index");
        lua.pushCFunction(L, sshGc);
        lua.setField(L, -2, "__gc");
        lua.pushCFunction(L, sshTostring);
        lua.setField(L, -2, "__tostring");
    }
    lua.pop(L, 1); // the metatable

    reg.register(L, "_ssh_open", makacSshOpen);
}

// ---------------------------------------------------------- metamethods ----

fn checkSession(L: *lua.State, arg: c_int) *SshSession {
    const p = lua.checkUdata(L, arg, MT) orelse unreachable;
    return @ptrCast(@alignCast(p));
}

/// Type-checked self + open-session guard shared by the methods.
fn checkOpen(L: *lua.State, op: []const u8) *SshSession {
    const self = checkSession(L, 1);
    if (self.closed) {
        raiseFmt(L, "makac.ssh: session '{s}' is closed — {s} is no longer allowed", .{ self.name, op });
    }
    return self;
}

fn sshIndex(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    _ = lua.checkUdata(L, 1, MT);
    if (lua.typeOf(L, 2) != lua.TSTRING) {
        lua.pushNil(L);
        return 1;
    }
    const key = lua.toLString(L, 2) orelse {
        lua.pushNil(L);
        return 1;
    };
    if (std.mem.eql(u8, key, "run")) {
        lua.pushCFunction(L, sessRun);
    } else if (std.mem.eql(u8, key, "put")) {
        lua.pushCFunction(L, sessPut);
    } else if (std.mem.eql(u8, key, "get")) {
        lua.pushCFunction(L, sessGet);
    } else if (std.mem.eql(u8, key, "close")) {
        lua.pushCFunction(L, sessClose);
    } else if (std.mem.eql(u8, key, "name")) {
        const self = checkSession(L, 1);
        lua.pushLString(L, self.name);
    } else if (std.mem.eql(u8, key, "port")) {
        const self = checkSession(L, 1);
        lua.pushInteger(L, self.port);
    } else {
        lua.pushNil(L);
    }
    return 1;
}

/// __gc: free host memory. Never spawns processes (that would be close()'s
/// `ssh -O exit`) and never raises — runs during GC / lua_close.
fn sshGc(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const p = lua.toUserdata(L, 1) orelse return 0;
    const self: *SshSession = @ptrCast(@alignCast(p));
    if (self.name.len != 0) self.allocator.free(self.name);
    if (self.config_path.len != 0) self.allocator.free(self.config_path);
    self.name = &.{};
    self.config_path = &.{};
    self.closed = true;
    return 0;
}

fn sshTostring(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = checkSession(L, 1);
    var buf: [512]u8 = undefined;
    const msg = if (self.closed)
        std.fmt.bufPrint(&buf, "makac.ssh: {s} (closed)", .{self.name}) catch "makac.ssh (closed)"
    else
        std.fmt.bufPrint(&buf, "makac.ssh: {s}", .{self.name}) catch "makac.ssh";
    lua.pushLString(L, msg);
    return 1;
}

// ---------------------------------------------------------- constructor ----

fn raiseFmt(L: *lua.State, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "makac.ssh: error";
    lua.raiseLString(L, msg);
}

fn oom(L: *lua.State) noreturn {
    lua.raise(L, "makac.ssh: out of memory");
}

fn optStringField(L: *lua.State, idx: c_int, field: [:0]const u8) ?[]const u8 {
    const t = lua.getField(L, idx, field);
    defer lua.pop(L, 1);
    if (t != lua.TSTRING) return null;
    return lua.toLString(L, -1);
}

/// makac._ssh_open(name, spec) -> session userdata
fn makacSshOpen(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;

    if (lua.typeOf(L, 1) != lua.TSTRING) {
        lua.raise(L, "makac._ssh_open: name must be a non-empty string");
    }
    const name = lua.toLString(L, 1) orelse "";
    if (name.len == 0) {
        lua.raise(L, "makac._ssh_open: name must be a non-empty string");
    }
    lua.checkType(L, 2, lua.TTABLE);

    const v = host(L);
    if (v.data_dir.len == 0) {
        lua.raise(L, "makac._ssh_open: no data directory (makac.data_dir is unset)");
    }

    const host_s = optStringField(L, 2, "host") orelse "";
    const user_s = optStringField(L, 2, "user") orelse "";
    if (host_s.len == 0) {
        lua.raise(L, "makac._ssh_open: spec.host must be a non-empty string");
    }
    if (user_s.len == 0) {
        lua.raise(L, "makac._ssh_open: spec.user must be a non-empty string");
    }
    if (!ssh.validTargetName(name)) {
        raiseFmt(L, "makac._ssh_open: invalid name '{s}' (allowed: [A-Za-z0-9._-])", .{name});
    }

    // port (default 22; travels on the command line, never in the config)
    var port: i32 = 22;
    {
        const t = lua.getField(L, 2, "port");
        if (t == lua.TNUMBER) {
            port = @intCast(lua.toInteger(L, -1));
            lua.pop(L, 1);
            if (port < 1 or port > 65535) {
                lua.raise(L, "makac._ssh_open: spec.port out of range [1;65535]");
            }
        } else if (t != lua.TNIL) {
            lua.pop(L, 1);
            lua.raise(L, "makac._ssh_open: spec.port must be a number");
        } else {
            lua.pop(L, 1);
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Per-invocation (global) options: connection multiplexing, so the first
    // command authenticates and everything later rides the master.
    var global: std.ArrayList(ssh.Option) = .empty;
    global.append(arena, .{ .key = "ControlMaster", .value = .{ .string = "auto" } }) catch oom(L);
    global.append(arena, .{ .key = "ControlPersist", .value = .{ .string = "10m" } }) catch oom(L);
    // relative -> anchored to <state_dir>/ssh/ by generateConfig
    global.append(arena, .{ .key = "ControlPath", .value = .{ .string = "ctl" } }) catch oom(L);

    var target: std.ArrayList(ssh.Option) = .empty;
    target.append(arena, .{ .key = "HostName", .value = .{ .string = host_s } }) catch oom(L);
    target.append(arena, .{ .key = "User", .value = .{ .string = user_s } }) catch oom(L);

    // extra ssh options: string keys -> scalar values (others silently skipped)
    const t_opts = lua.getField(L, 2, "options");
    if (t_opts == lua.TTABLE) {
        const opts_idx = lua.absindex(L, -1);
        lua.pushNil(L);
        while (lua.next(L, opts_idx) != 0) {
            if (lua.toLString(L, -2)) |k| {
                const key = arena.dupe(u8, k) catch oom(L);
                const value: ?ssh.OptionValue = switch (lua.typeOf(L, -1)) {
                    lua.TSTRING => .{ .string = arena.dupe(u8, lua.toLString(L, -1) orelse "") catch oom(L) },
                    lua.TBOOLEAN => .{ .boolean = lua.toBoolean(L, -1) },
                    lua.TNUMBER => if (lua.c.lua_isinteger(L, -1) != 0)
                        .{ .integer = lua.toInteger(L, -1) }
                    else
                        .{ .float = lua.toNumber(L, -1) },
                    else => null,
                };
                if (value) |val| {
                    target.append(arena, .{ .key = key, .value = val }) catch oom(L);
                }
            }
            lua.pop(L, 1);
        }
    }
    lua.pop(L, 1); // options table / nil

    const state_dir = std.fs.path.join(arena, &.{ v.data_dir, "targets", name }) catch oom(L);
    const config_path = ssh.generateConfig(v.io, v.allocator, state_dir, global.items, target.items) catch |e| {
        raiseFmt(
            L,
            "makac._ssh_open: failed to set up session '{s}': {s}",
            .{ name, ssh.genErrorString(e) },
        );
    };

    const name_copy = v.allocator.dupe(u8, name) catch {
        v.allocator.free(config_path);
        oom(L);
    };

    const ud = lua.newUserdata(L, SshSession);
    ud.* = .{
        .name = name_copy,
        .config_path = config_path,
        .port = port,
        .closed = false,
        .allocator = v.allocator,
    };
    lua.setMetatable(L, MT);
    return 1;
}

// ------------------------------------------------------------- methods -----

/// sess:run(command, opts?) -> { code, stdout, stderr }
/// `command` is ONE string (ssh passes it to the remote login shell as a single
/// word); argv joining/quoting happens on the Lua side. `opts.stdin` feeds the
/// command's stdin (non-interactive).
fn sessRun(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = checkOpen(L, "run");
    const command_lua = lua.checkLString(L, 2);
    if (command_lua.len == 0) {
        lua.raise(L, "makac.ssh: run: command must not be empty");
    }
    var stdin_lua: ?[]const u8 = null;
    if (!lua.isNoneOrNil(L, 3)) {
        lua.checkType(L, 3, lua.TTABLE);
        if (optStringField(L, 3, "stdin")) |s| stdin_lua = s;
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const command = arena.dupe(u8, command_lua) catch oom(L);
    const stdin_data: ?[]const u8 = if (stdin_lua) |s| arena.dupe(u8, s) catch oom(L) else null;

    const argv = ssh.sshArgv(arena, self.config_path, self.port, command) catch oom(L);
    const res = sp.run(argv, .{ .allocator = arena, .stdin_data = stdin_data }) catch |e| {
        raiseFmt(
            L,
            "makac.ssh: run: failed to execute (is ssh on PATH? host reachable?): {s}",
            .{sp.errorString(e)},
        );
    };
    lua.createTable(L, 0, 3);
    lua.pushInteger(L, res.code);
    lua.setField(L, -2, "code");
    lua.pushLString(L, res.stdout);
    lua.setField(L, -2, "stdout");
    lua.pushLString(L, res.stderr);
    lua.setField(L, -2, "stderr");
    return 1;
}

/// sess:put(local_path, remote_path) — raises on failure.
fn sessPut(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = checkOpen(L, "put");
    const local = lua.checkLString(L, 2);
    const remote = lua.checkLString(L, 3);
    if (local.len == 0) lua.raise(L, "makac.ssh: put: local path must be a non-empty string");
    if (remote.len == 0) lua.raise(L, "makac.ssh: put: remote path must be a non-empty string");

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const local_copy = arena.dupe(u8, local) catch oom(L);
    const remote_copy = arena.dupe(u8, remote) catch oom(L);
    const recursive = pathIsDir(host(L).io, local);
    const argv = ssh.scpPutArgv(arena, self.config_path, self.port, local_copy, remote_copy, recursive) catch oom(L);
    const res = sp.run(argv, .{ .allocator = arena }) catch |e| {
        raiseFmt(L, "makac.ssh: put: failed to execute scp: {s}", .{sp.errorString(e)});
    };
    if (res.code != 0) {
        raiseFmt(L, "makac.ssh: put: upload failed (exit {d}): {s}", .{ res.code, res.stderr });
    }
    return 0;
}

/// sess:get(remote_path, local_path) — raises on failure. Always recursive,
/// like the reference (`scp -r`).
fn sessGet(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = checkOpen(L, "get");
    const remote = lua.checkLString(L, 2);
    const local = lua.checkLString(L, 3);
    if (remote.len == 0) lua.raise(L, "makac.ssh: get: remote path must be a non-empty string");
    if (local.len == 0) lua.raise(L, "makac.ssh: get: local path must be a non-empty string");

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const remote_copy = arena.dupe(u8, remote) catch oom(L);
    const local_copy = arena.dupe(u8, local) catch oom(L);
    const argv = ssh.scpGetArgv(arena, self.config_path, self.port, remote_copy, local_copy, true) catch oom(L);
    const res = sp.run(argv, .{ .allocator = arena }) catch |e| {
        raiseFmt(L, "makac.ssh: get: failed to execute scp: {s}", .{sp.errorString(e)});
    };
    if (res.code != 0) {
        raiseFmt(L, "makac.ssh: get: download failed (exit {d}): {s}", .{ res.code, res.stderr });
    }
    return 0;
}

/// sess:close() — tears down the control master (best-effort) and marks the
/// session closed. Idempotent. Never raises on a failed `ssh -O exit`.
fn sessClose(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const self = checkSession(L, 1);
    if (self.closed) return 0;
    self.closed = true;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = ssh.sshExitArgv(arena, self.config_path, self.port) catch return 0;
    _ = sp.run(argv, .{ .allocator = arena }) catch return 0;
    return 0;
}

fn pathIsDir(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return st.kind == .directory;
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

test "binding shape and the prelude shquote security contract" {
    const vm = try VM.new(testing.allocator, testing.io, .{});
    defer vm.deinit();
    try vm.runString(
        \\assert(type(makac._ssh_open) == "function", "_ssh_open missing")
        \\assert(type(makac._shquote) == "function", "_shquote missing")
        \\-- bare words pass through; unsafe words are single-quoted with the
        \\-- standard '\'' escape for embedded quotes (the security contract)
        \\assert(makac._shquote("abc") == "abc")
        \\assert(makac._shquote("/a/b-c.d") == "/a/b-c.d")
        \\assert(makac._shquote("a b") == "'a b'")
        \\assert(makac._shquote("") == "''")
        \\assert(makac._shquote("it's") == [['it'\''s']])
        \\assert(makac._shquote("a;rm -rf /") == "'a;rm -rf /'")
    , "@ssh_test");
}

test "_ssh_open rejects path traversal in the target name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(data_dir);

    const vm = try VM.new(testing.allocator, testing.io, .{ .data_dir = data_dir });
    defer vm.deinit();
    try vm.runString(
        \\local ok, err = pcall(makac._ssh_open, "..", { host = "h", user = "u" })
        \\assert(not ok and tostring(err):find("invalid name", 1, true), tostring(err))
        \\local ok2, err2 = pcall(makac._ssh_open, "a/../b", { host = "h", user = "u" })
        \\assert(not ok2 and tostring(err2):find("invalid name", 1, true), tostring(err2))
        \\local ok3, err3 = pcall(makac._ssh_open, "vm1", { host = "h", user = "u" })
        \\assert(ok3, tostring(err3))
        \\-- validation happens before any connection: spec errors still raise
        \\local ok4, err4 = pcall(makac._ssh_open, "vm2", { user = "u" })
        \\assert(not ok4 and tostring(err4):find("spec.host", 1, true), tostring(err4))
    , "@ssh_test");
}
