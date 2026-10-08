// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// exec.zig — the makac.exec Lua binding over the subprocess core.
//
// `makac.exec(argv, opts)` runs argv directly (no shell interpretation) and
// returns { code, stdout, stderr, timed_out }. A non-zero exit and a timeout
// are DATA, not errors; only failing to spawn the program (or an on_line
// failure) raises.
//
// argv words are coerced the way lua_tolstring coerces — strings
// and numbers become strings, anything else is an error.

const std = @import("std");
const lua = @import("../lua.zig");
const reg = @import("register.zig");
const sp = @import("../subprocess.zig");

pub fn registerExec(L: *lua.State) void {
    reg.register(L, "exec", makacExec);
    reg.register(L, "sha256", makacSha256);
}

/// makac.sha256(s) -> lowercase SHA256 hex digest of the given string.
/// Length-aware: the prelude hashes storage-key material containing NUL
/// separators, so a C-string conversion would truncate.
fn makacSha256(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const s = lua.checkLString(L, 1);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(s, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    lua.pushLString(L, &hex);
    return 1;
}

/// Per-run state shared with the plain-proc on_line bridge: the callback's
/// stack slot (kept live so the GC cannot collect it) and the latched error
/// from a raising callback. Fixed-size message copy keeps the error path
/// allocation-free (it may run under a Lua longjmp).
const OnLineState = struct {
    L: *lua.State,
    cb_idx: c_int = 0,
    failed: bool = false,
    msg_buf: [512]u8 = undefined,
    msg_len: usize = 0,
};

fn onLineBridge(ctx: ?*anyopaque, stream: []const u8, line: []const u8) bool {
    const st: *OnLineState = @ptrCast(@alignCast(ctx.?));
    const L = st.L;
    lua.pushvalue(L, st.cb_idx);
    lua.pushLString(L, line);
    lua.pushLString(L, stream);
    if (lua.pcall(L, 2, 0, 0) != lua.OK) {
        if (lua.toLString(L, -1)) |s| {
            const n = @min(s.len, st.msg_buf.len);
            @memcpy(st.msg_buf[0..n], s[0..n]);
            st.msg_len = n;
        }
        lua.pop(L, 1);
        st.failed = true;
        return false;
    }
    return true;
}

fn makacExec(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    return makacExecInner(L, &arena_state) catch {
        arena_state.deinit();
        lua.raiseLString(L, "makac.exec: out of memory");
    };
}

fn failFmt(
    L: *lua.State,
    arena_state: *std.heap.ArenaAllocator,
    comptime fmt: []const u8,
    args: anytype,
) noreturn {
    var buf: [2048]u8 = undefined;
    // Copy the message out first: lua_pushlstring copies, so the arena (and
    // this buffer) may be released before the longjmp.
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "makac.exec: error";
    arena_state.deinit();
    lua.raiseLString(L, msg);
}

fn optStringField(L: *lua.State, idx: c_int, field: [:0]const u8) ?[]const u8 {
    const t = lua.getField(L, idx, field);
    defer lua.pop(L, 1);
    if (t != lua.TSTRING) return null;
    return lua.toLString(L, -1);
}

/// Merge `KEY=VALUE` overrides on top of the current process environment,
/// preserving the rest (the reference's `_merge_env`). An empty override list
/// means "inherit" (null).
fn mergeEnv(
    arena: std.mem.Allocator,
    overrides: []const []const u8,
) error{OutOfMemory}!?[]const []const u8 {
    if (overrides.len == 0) return null;
    var merged: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.c.environ[i]) |e| : (i += 1) {
        try merged.append(arena, std.mem.span(e));
    }
    outer: for (overrides) |ov| {
        const eq = std.mem.indexOfScalar(u8, ov, '=') orelse {
            try merged.append(arena, ov);
            continue;
        };
        const prefix = ov[0 .. eq + 1];
        for (merged.items, 0..) |e, j| {
            if (std.mem.startsWith(u8, e, prefix)) {
                merged.items[j] = ov;
                continue :outer;
            }
        }
        try merged.append(arena, ov);
    }
    return try merged.toOwnedSlice(arena);
}

fn makacExecInner(L: *lua.State, arena_state: *std.heap.ArenaAllocator) error{OutOfMemory}!c_int {
    const arena = arena_state.allocator();

    lua.checkType(L, 1, lua.TTABLE);

    const nargs = lua.rawLen(L, 1);
    if (nargs == 0) return failFmt(L, arena_state, "makac.exec: argv must not be empty", .{});

    var argv: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i <= nargs) : (i += 1) {
        _ = lua.rawGetI(L, 1, @intCast(i));
        const raw = lua.toLString(L, -1) orelse {
            lua.pop(L, 1);
            return failFmt(L, arena_state, "makac.exec: argv[{d}] must be a string", .{i});
        };
        const copy = try arena.dupe(u8, raw);
        try argv.append(arena, copy);
        lua.pop(L, 1);
    }

    var chdir: []const u8 = "";
    var stdin_data: ?[]const u8 = null;
    var env: ?[]const []const u8 = null;
    var join = false;
    var timeout_s: f64 = 0;
    var on_line: ?sp.LineCallback = null;
    var cb_state = OnLineState{ .L = L };

    if (!lua.isNoneOrNil(L, 2)) {
        lua.checkType(L, 2, lua.TTABLE);

        if (optStringField(L, 2, "chdir")) |s| chdir = try arena.dupe(u8, s);
        if (optStringField(L, 2, "stdin")) |s| stdin_data = try arena.dupe(u8, s);

        _ = lua.getField(L, 2, "join");
        join = lua.toBoolean(L, -1);
        lua.pop(L, 1);

        const t_timeout = lua.getField(L, 2, "timeout_s");
        if (t_timeout == lua.TNUMBER) {
            timeout_s = @floatCast(lua.toNumber(L, -1));
            lua.pop(L, 1);
            if (timeout_s < 0) {
                return failFmt(L, arena_state, "makac.exec: opts.timeout_s must not be negative", .{});
            }
        } else if (t_timeout != lua.TNIL) {
            lua.pop(L, 1);
            return failFmt(L, arena_state, "makac.exec: opts.timeout_s must be a number (seconds)", .{});
        } else {
            lua.pop(L, 1);
        }

        const t_on_line = lua.getField(L, 2, "on_line");
        if (t_on_line == lua.TFUNCTION) {
            // Leave the function on the stack: cb_idx must stay a live slot.
            cb_state.cb_idx = lua.absindex(L, -1);
            on_line = onLineBridge;
        } else if (t_on_line != lua.TNIL) {
            lua.pop(L, 1);
            return failFmt(L, arena_state, "makac.exec: opts.on_line must be a function(line, stream)", .{});
        } else {
            lua.pop(L, 1);
        }

        const t_env = lua.getField(L, 2, "env");
        if (t_env == lua.TTABLE) {
            var overrides: std.ArrayList([]const u8) = .empty;
            lua.pushNil(L);
            while (lua.next(L, -2) != 0) {
                const k = lua.toLString(L, -2);
                const v = lua.toLString(L, -1);
                if (k != null and v != null) {
                    const kv = try std.fmt.allocPrint(arena, "{s}={s}", .{ k.?, v.? });
                    try overrides.append(arena, kv);
                }
                lua.pop(L, 1);
            }
            lua.pop(L, 1); // env table
            env = try mergeEnv(arena, overrides.items);
        } else {
            lua.pop(L, 1);
        }
    }

    const res = sp.run(argv.items, .{
        .working_dir = chdir,
        .env = env,
        .stdin_data = stdin_data,
        .join_stderr = join,
        .timeout_s = timeout_s,
        .on_line = on_line,
        .on_line_ctx = &cb_state,
        .allocator = arena,
    }) catch |e| {
        return failFmt(L, arena_state, "makac.exec: failed to spawn '{s}': {s}", .{
            argv.items[0],
            sp.errorString(e),
        });
    };

    if (cb_state.failed) {
        const msg = cb_state.msg_buf[0..cb_state.msg_len];
        return failFmt(L, arena_state, "makac.exec: on_line callback failed: {s}", .{msg});
    }

    lua.createTable(L, 0, 4);
    lua.pushInteger(L, res.code);
    lua.setField(L, -2, "code");
    lua.pushLString(L, res.stdout);
    lua.setField(L, -2, "stdout");
    lua.pushLString(L, res.stderr);
    lua.setField(L, -2, "stderr");
    lua.pushBoolean(L, res.timed_out);
    lua.setField(L, -2, "timed_out");
    return 1;
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

fn newLua() !*lua.State {
    const L = lua.newState() orelse return error.OutOfMemory;
    lua.openlibs(L);
    registerExec(L);
    return L;
}

/// Run `src` under the state, asserting it completes without error. On a Lua
/// error the message is surfaced through the returned error's name only; for
/// diagnostics, run a smaller chunk. Tests below assert with Lua `assert`.
fn runLua(L: *lua.State, src: []const u8) !void {
    if (lua.loadBuffer(L, src, "@test") != lua.OK) {
        std.debug.print("load error: {s}\n", .{lua.peekError(L)});
        lua.pop(L, 1);
        return error.LuaError;
    }
    if (lua.pcall(L, 0, 0, 0) != lua.OK) {
        std.debug.print("runtime error: {s}\n", .{lua.peekError(L)});
        lua.pop(L, 1);
        return error.LuaError;
    }
}

test "exec captures stdout/stderr/code; nonzero exit is data" {
    const L = try newLua();
    defer lua.close(L);
    try runLua(L,
        \\local r = makac.exec({"sh", "-c", "printf out; printf err >&2; exit 3"})
        \\assert(r.code == 3, "code " .. tostring(r.code))
        \\assert(r.stdout == "out", "stdout " .. r.stdout)
        \\assert(r.stderr == "err", "stderr " .. r.stderr)
        \\assert(r.timed_out == false)
    );
}

test "exec coerces numeric argv words" {
    const L = try newLua();
    defer lua.close(L);
    try runLua(L,
        \\local r = makac.exec({"printf", 5})
        \\assert(r.code == 0, tostring(r.code))
        \\assert(r.stdout == "5", "got " .. r.stdout)
    );
}

test "exec empty argv raises" {
    const L = try newLua();
    defer lua.close(L);
    try runLua(L,
        \\local ok, err = pcall(makac.exec, {})
        \\assert(not ok, "expected an error")
        \\assert(tostring(err):find("argv must not be empty", 1, true) ~= nil, tostring(err))
    );
}

test "exec missing program raises with the program name" {
    const L = try newLua();
    defer lua.close(L);
    try runLua(L,
        \\local ok, err = pcall(makac.exec, {"definitely-not-real-xyz"})
        \\assert(not ok, "expected an error")
        \\assert(tostring(err):find("definitely-not-real-xyz", 1, true) ~= nil, tostring(err))
    );
}

test "exec opts chdir changes the working directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);

    const L = try newLua();
    defer lua.close(L);
    const src = try std.fmt.allocPrint(
        testing.allocator,
        \\local r = makac.exec({{"sh", "-c", "pwd"}}, {{ chdir = "{s}" }})
        \\assert(r.code == 0, tostring(r.code))
        \\assert(r.stdout:gsub("\n$", "") == "{s}", r.stdout)
    ,
        .{ dir, dir },
    );
    defer testing.allocator.free(src);
    try runLua(L, src);
}

test "exec opts env merges onto the parent environment" {
    const L = try newLua();
    defer lua.close(L);
    try runLua(L,
        \\local r = makac.exec({"printenv", "MAKAC_UNIT_FOO"}, { env = { MAKAC_UNIT_FOO = "unit-value" } })
        \\assert(r.code == 0)
        \\assert(r.stdout == "unit-value\n", r.stdout)
        \\-- PATH survives the merge: `printenv` itself resolved and ran
    );
}

test "exec opts stdin feeds the command" {
    const L = try newLua();
    defer lua.close(L);
    try runLua(L,
        \\local r = makac.exec({"cat"}, { stdin = "hello" })
        \\assert(r.stdout == "hello", r.stdout)
    );
}

test "exec opts join merges stderr into stdout" {
    const L = try newLua();
    defer lua.close(L);
    try runLua(L,
        \\local r = makac.exec({"sh", "-c", "printf out; printf err >&2"}, { join = true })
        \\assert(r.stdout == "outerr", r.stdout)
        \\assert(r.stderr == "", r.stderr)
    );
}

test "exec opts on_line sees complete lines in order" {
    const L = try newLua();
    defer lua.close(L);
    try runLua(L,
        \\local seen = {}
        \\local r = makac.exec({"sh", "-c", "printf 'a\\nb\\nc\\n'"}, {
        \\  on_line = function(line, stream) seen[#seen+1] = stream .. ":" .. line end,
        \\})
        \\assert(table.concat(seen, ",") == "stdout:a,stdout:b,stdout:c", table.concat(seen, ","))
        \\assert(r.stdout == "a\nb\nc\n", r.stdout)
    );
}

test "exec opts on_line error aborts and raises" {
    const L = try newLua();
    defer lua.close(L);
    try runLua(L,
        \\local ok, err = pcall(makac.exec, {"sh", "-c", "printf 'a\\n'; sleep 5"}, {
        \\  timeout_s = 10,
        \\  on_line = function() error("callback-boom") end,
        \\})
        \\assert(not ok, "expected an error")
        \\assert(tostring(err):find("on_line callback failed", 1, true) ~= nil, tostring(err))
        \\assert(tostring(err):find("callback-boom", 1, true) ~= nil, tostring(err))
    );
}

test "exec opts timeout_s sets timed_out" {
    const L = try newLua();
    defer lua.close(L);
    try runLua(L,
        \\local r = makac.exec({"sleep", "30"}, { timeout_s = 0.2 })
        \\assert(r.timed_out == true)
        \\assert(r.code ~= 0, tostring(r.code))
    );
}

test "exec rejects a negative timeout_s and a bad on_line" {
    const L = try newLua();
    defer lua.close(L);
    try runLua(L,
        \\local ok1 = pcall(makac.exec, {"true"}, { timeout_s = -1 })
        \\assert(not ok1, "negative timeout must raise")
        \\local ok2 = pcall(makac.exec, {"true"}, { on_line = 5 })
        \\assert(not ok2, "non-function on_line must raise")
    );
}

test "flat makac.sha256: known vectors and NUL significance" {
    const L = try newLua();
    defer lua.close(L);
    try runLua(L,
        \\assert(makac.sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        \\assert(makac.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        \\assert(makac.sha256("a\\0b") ~= makac.sha256("ab"), "NUL is significant")
    );
}
