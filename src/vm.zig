// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// vm.zig — the makac VM: a Lua 5.4 state plus the embedded prelude and the
// script execution context (arg / SCRIPT_DIR / PROJECT_DIR).

const std = @import("std");
const lua = @import("lua.zig");

/// The prelude is vendored verbatim at the repository root (`prelude.lua`,
/// symlinked into `src/` so it is inside the package path) and baked into the
/// binary so a built makac is fully self-contained.
pub const prelude_src = @embedFile("prelude.lua");

pub const Options = struct {
    /// Resolved `.makac` data directory ("" when data-dir-less, e.g. tests).
    data_dir: []const u8 = "",
    /// Directory holding the `.makac` data dir and `makac_project.lua`; nil
    /// when the VM has no project.
    project_root: ?[]const u8 = null,
};

pub const VM = struct {
    L: *lua.State,
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    project_root: ?[]const u8,
    last_error: ?[]u8 = null,

    /// Create a state, open the standard library, register host primitives
    /// (grows task by task) and evaluate the embedded prelude. User Lua can
    /// only run after this returns.
    pub fn new(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: Options,
    ) !*VM {
        // The process ignores SIGPIPE; a write to a  closed socket (QMP,
        // spawned children) then surfaces EPIPE instead of killing makac.
        ignoreSigpipe();

        const L = lua.newState() orelse return error.LuaOutOfMemory;
        errdefer lua.close(L);
        lua.openlibs(L);

        const self = try allocator.create(VM);
        self.* = .{
            .L = L,
            .io = io,
            .allocator = allocator,
            .data_dir = options.data_dir,
            .project_root = options.project_root,
        };
        errdefer allocator.destroy(self);

        // Bare `lua_State` host primitives reach the VM (io/allocator) through
        // the registry; the pointer outlives every C call until close.
        lua.pushLightUserdata(L, self);
        lua.setField(L, lua.REGISTRYINDEX, "makac.vm");

        registerBuiltins(self);

        self.runString(prelude_src, "@prelude.lua") catch {
            // The prelude is baked in and under our control: a failure here is
            // a makac bug, never user error.
            std.debug.print(
                "makac: internal error evaluating embedded prelude: {s}\n",
                .{self.lastError()},
            );
            return error.PreludeFailed;
        };

        // Publish the embedded LuaCATS stub now that the `makac` table exists.
        @import("vm/luals.zig").exposeStub(self);

        // Expose the data directory to Lua helpers (may be ""), then the
        // project root global (nil when there is no project).
        if (self.data_dir.len > 0) {
            _ = lua.getGlobal(L, "makac");
            if (lua.typeOf(L, -1) == lua.TTABLE) {
                lua.pushLString(L, self.data_dir);
                lua.setField(L, -2, "data_dir");
            }
            lua.pop(L, 1);
        }
        if (self.project_root) |root| {
            lua.pushLString(L, root);
            lua.setGlobal(L, "PROJECT_DIR");
        }
        return self;
    }

    pub fn deinit(self: *VM) void {
        if (self.last_error) |e| self.allocator.free(e);
        lua.close(self.L);
        self.allocator.destroy(self);
    }

    /// Host primitives registered before the embedded prelude is evaluated:
    /// makac.exec/sha256, time, env, random_hex and fs today; json/proc/qmp/...
    /// join as tasks land. Registration lives in vm/register.zig.
    fn registerBuiltins(self: *VM) void {
        @import("vm/register.zig").install(self.L);
    }

    // ------------------------------------------------------------ errors ----

    pub fn lastError(self: *VM) []const u8 {
        return self.last_error orelse "";
    }

    fn setError(self: *VM, msg: []const u8) void {
        if (self.last_error) |old| self.allocator.free(old);
        self.last_error = self.allocator.dupe(u8, msg) catch null;
    }

    /// Copy the message currently on top of the Lua stack into `last_error`.
    fn captureError(self: *VM) void {
        const msg = lua.peekError(self.L);
        self.setError(msg);
    }

    // ------------------------------------------------------- eval / run -----

    /// Evaluate `src` and return an error on compile or runtime failure; the
    /// verbatim Lua message is available through `lastError()`.
    pub fn runString(self: *VM, src: []const u8, chunk_name: [:0]const u8) !void {
        const L = self.L;
        const top = lua.gettop(L);
        defer lua.settop(L, top);

        if (lua.loadBuffer(L, src, chunk_name) != lua.OK) {
            self.captureError();
            return error.LuaError;
        }
        if (lua.pcall(L, 0, 0, 0) != lua.OK) {
            self.captureError();
            return error.LuaError;
        }
    }

    /// Load and evaluate the Lua file at `path`. The chunk is named `@path`
    /// so error messages refer to the file. A leading shebang line is
    /// replaced by a lone newline (exactly what luaL_loadfilex does) so
    /// tracebacks keep matching the on-disk line numbers.
    pub fn runFile(self: *VM, path: []const u8, args: []const []const u8) !void {
        const alloc = self.allocator;

        const src = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            alloc,
            .limited(max_script_bytes),
        ) catch |e| {
            const msg = std.fmt.allocPrint(
                alloc,
                "cannot read file '{s}': {s}",
                .{ path, @errorName(e) },
            ) catch null;
            if (msg) |m| {
                if (self.last_error) |old| alloc.free(old);
                self.last_error = m;
            }
            return error.ReadFile;
        };
        defer alloc.free(src);

        var body: []const u8 = src;
        var stripped: ?[]u8 = null;
        defer if (stripped) |s| alloc.free(s);
        if (body.len > 0 and body[0] == '#') {
            if (std.mem.indexOfScalar(u8, body, '\n')) |nl| {
                stripped = try std.fmt.allocPrint(alloc, "\n{s}", .{body[nl + 1 ..]});
            } else {
                // A file that is only a shebang line is an empty script.
                stripped = try alloc.dupe(u8, "\n");
            }
            body = stripped.?;
        }

        try self.setScriptContext(path, args);

        const chunk = try std.fmt.allocPrintSentinel(alloc, "@{s}", .{path}, 0);
        defer alloc.free(chunk);
        try self.runString(body, chunk);
    }

    /// Expose the script's execution context as Lua globals:
    ///   arg        arg[0] = script path, arg[1..n] = following arguments
    ///   SCRIPT_DIR absolute directory the script resides in
    pub fn setScriptContext(
        self: *VM,
        script_path: []const u8,
        args: []const []const u8,
    ) !void {
        const L = self.L;
        const top = lua.gettop(L);
        defer lua.settop(L, top);

        lua.createTable(L, @intCast(args.len), 1);
        lua.pushLString(L, script_path);
        lua.rawSetI(L, -2, 0);
        for (args, 0..) |a, i| {
            lua.pushLString(L, a);
            lua.rawSetI(L, -2, @intCast(i + 1));
        }
        lua.setGlobal(L, "arg");

        const dir = try self.scriptDir(script_path);
        defer self.allocator.free(dir);
        lua.pushLString(L, dir);
        lua.setGlobal(L, "SCRIPT_DIR");
    }

    fn scriptDir(self: *VM, path: []const u8) ![]u8 {
        const alloc = self.allocator;
        const abs = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, alloc);
        defer alloc.free(abs);
        const dir = std.fs.path.dirname(abs) orelse ".";
        return alloc.dupe(u8, dir);
    }

    // ------------------------------------------------------ called Lua ----

    /// Push the function named by a dot path (e.g. "makac._doctor") onto the
    /// stack, or return false (having pushed nothing) when any component is
    /// missing/not a table and the final value is not a function.
    fn pushNamed(self: *VM, name: []const u8) bool {
        const L = self.L;
        var it = std.mem.splitScalar(u8, name, '.');
        const first = it.next() orelse return false;
        const first_z = self.allocator.dupeZ(u8, first) catch return false;
        defer self.allocator.free(first_z);
        if (lua.getGlobal(L, first_z) == lua.TNIL) {
            lua.pop(L, 1);
            return false;
        }
        while (it.next()) |part| {
            if (lua.typeOf(L, -1) != lua.TTABLE) {
                lua.pop(L, 1);
                return false;
            }
            const part_z = self.allocator.dupeZ(u8, part) catch {
                lua.pop(L, 1);
                return false;
            };
            defer self.allocator.free(part_z);
            _ = lua.getField(L, -1, part_z);
            lua.remove(L, -2);
        }
        if (lua.typeOf(L, -1) != lua.TFUNCTION) {
            lua.pop(L, 1);
            return false;
        }
        return true;
    }

    /// Call the zero-argument Lua function named by a dot path. Returns false
    /// when it cannot be resolved; `error.LuaError` when it raises (see
    /// `lastError()`).
    pub fn callNamed(self: *VM, name: []const u8) !bool {
        const L = self.L;
        const top = lua.gettop(L);
        defer lua.settop(L, top);
        if (!self.pushNamed(name)) return false;
        if (lua.pcall(L, 0, 0, 0) != lua.OK) {
            self.captureError();
            return error.LuaError;
        }
        return true;
    }

    /// Call the one-string-argument Lua function named by a dot path and
    /// return its integer result. Returns null when it cannot be resolved;
    /// `error.LuaError` when it raises (see `lastError()`).
    pub fn callStringInt(self: *VM, name: []const u8, arg: []const u8) !?i64 {
        const L = self.L;
        const top = lua.gettop(L);
        defer lua.settop(L, top);
        if (!self.pushNamed(name)) return null;
        lua.pushLString(L, arg);
        if (lua.pcall(L, 1, 1, 0) != lua.OK) {
            self.captureError();
            return error.LuaError;
        }
        return @intCast(lua.toInteger(L, -1));
    }
};

// Fail loudly rather than OOM on a runaway script, but be generous.
const max_script_bytes: usize = 64 * 1024 * 1024;

/// Ignore SIGPIPE once per process (idempotent, cheap).
fn ignoreSigpipe() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &act, null);
}

// --------------------------------------------------------------- tests -----

fn newTestVM() !*VM {
    return VM.new(std.testing.allocator, std.testing.io, .{});
}

test "new/eval/pcall: success and error surface" {
    const vm = try newTestVM();
    defer vm.deinit();

    try vm.runString("x = 40 + 2", "@test");
    try vm.runString("assert(x == 42)", "@test");

    try std.testing.expectError(
        error.LuaError,
        vm.runString("error('boom')", "@test"),
    );
    try std.testing.expect(std.mem.indexOf(u8, vm.lastError(), "boom") != null);

    // A syntax error is surfaced too, not swallowed.
    try std.testing.expectError(
        error.LuaError,
        vm.runString("this is not lua", "@test"),
    );
}

test "prelude defines step and makac.define_action" {
    const vm = try newTestVM();
    defer vm.deinit();

    try vm.runString("assert(type(step) == 'function', 'step missing')", "@test");
    try vm.runString(
        "assert(type(makac.define_action) == 'function', 'define_action missing')",
        "@test",
    );
    try vm.runString("assert(makac.host ~= nil, 'makac.host missing')", "@test");
}

test "host primitives are registered before the prelude" {
    const vm = try newTestVM();
    defer vm.deinit();

    try vm.runString("assert(type(makac.exec) == 'function', 'makac.exec missing')", "@test");
    try vm.runString("assert(type(makac.time) == 'table', 'makac.time missing')", "@test");
    try vm.runString("assert(type(makac.time.now) == 'function', 'time.now missing')", "@test");
    try vm.runString("assert(type(makac.json) == 'table', 'makac.json missing')", "@test");
    try vm.runString("assert(type(makac.json.dumps) == 'function', 'json.dumps missing')", "@test");
    try vm.runString("assert(type(makac.json.loads) == 'function', 'json.loads missing')", "@test");
    try vm.runString("assert(type(makac.fs) == 'table', 'makac.fs missing')", "@test");
    try vm.runString("assert(type(makac.fs.path) == 'function', 'makac.fs.path missing')", "@test");
    try vm.runString("assert(type(makac.fs.cwd) == 'function', 'makac.fs.cwd missing')", "@test");
    try vm.runString("assert(type(makac.fs.open_dir) == 'function', 'makac.fs.open_dir missing')", "@test");
    try vm.runString("assert(makac.listdir == makac.fs.listdir, 'flat listdir alias')", "@test");
    try vm.runString("assert(type(makac.env) == 'table', 'makac.env missing')", "@test");
    try vm.runString("assert(type(makac.env.all) == 'function', 'env.all missing')", "@test");
    try vm.runString("assert(type(makac.env.version) == 'function', 'env.version missing')", "@test");
    try vm.runString("assert(type(makac.env.makac_path) == 'function', 'env.makac_path missing')", "@test");
    try vm.runString("assert(type(makac.random_hex) == 'function', 'makac.random_hex missing')", "@test");
    try vm.runString("assert(type(makac.pid_alive) == 'function', 'makac.pid_alive missing')", "@test");
    try vm.runString("assert(type(makac.spawn) == 'function', 'makac.spawn missing')", "@test");
    // the shell action is registered by the prelude and wires up to host.run
    try vm.runString(
        "assert(type(makac.registry.actions.shell) == 'function', 'shell action missing')",
        "@test",
    );
}

test "shebang skip keeps line numbers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{
        .sub_path = "bad.lua",
        .data = "#!/usr/bin/env makac\nerror('boom')\n",
    });
    const path = try tmp.dir.realPathFileAlloc(io, "bad.lua", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const vm = try newTestVM();
    defer vm.deinit();

    try std.testing.expectError(error.LuaError, vm.runFile(path, &.{}));
    try std.testing.expect(std.mem.indexOf(u8, vm.lastError(), ":2:") != null);
}

test "shebang-only file is an empty script" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{
        .sub_path = "lone.lua",
        .data = "#!/usr/bin/env makac",
    });
    const path = try tmp.dir.realPathFileAlloc(io, "lone.lua", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const vm = try newTestVM();
    defer vm.deinit();

    try vm.runFile(path, &.{});
}

test "script context globals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{
        .sub_path = "ctx.lua",
        .data =
        \\assert(arg[0] ~= nil)
        \\assert(arg[1] == "one")
        \\assert(arg[2] == "two")
        \\assert(type(SCRIPT_DIR) == "string" and SCRIPT_DIR ~= "")
        \\ctx_ok = true
        ,
    });
    const path = try tmp.dir.realPathFileAlloc(io, "ctx.lua", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const vm = try newTestVM();
    defer vm.deinit();

    try vm.runFile(path, &.{ "one", "two" });
    try vm.runString("assert(ctx_ok == true)", "@test");
}
