// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ap = @import("argparse.zig");
const dd = @import("datadir.zig");
const vm_mod = @import("vm.zig");
const version = @import("version.zig");

const USAGE =
    \\usage: makac [--version] <command> [args]
    \\       makac <workflow> [args...]
    \\
    \\commands:
    \\  init <path>                  initialize a .makac data directory
    \\  run <workflow> [args...]     run a workflow file
    \\  fetch                        fetch packages listed in makac_project.lua
    \\  doctor [name...]             report the health of makac and its packages
    \\
    \\If the first argument is not a command, it is treated as a workflow file to
    \\run ('makac foo.lua a b c' is 'makac run foo.lua a b c'). Arguments after
    \\the workflow are passed to it in the global 'arg' table; the script also
    \\sees the globals SCRIPT_DIR (its own directory) and PROJECT_DIR (the root
    \\holding .makac and makac_project.lua).
    \\
    \\A workflow may also run directly via a shebang line ('#!/usr/bin/env makac').
    \\Outside a project (no '.makac'/'.git' ancestor) workflows run without a
    \\data directory: packages are not loaded and PROJECT_DIR is unset.
    \\
    \\flags:
    \\  --version       print version (major.minor) and exit
    \\
;

const version_flag = ap.Flag{
    .long = "version",
    .desc = "print version (major.minor) and exit",
    .value = .none,
};

var init_cmd = ap.Command{ .name = "init", .help = "initialize a .makac data directory" };
var run_cmd = ap.Command{ .name = "run", .help = "run a workflow file" };
var fetch_cmd = ap.Command{ .name = "fetch", .help = "fetch packages listed in makac_project.lua" };
var doctor_cmd = ap.Command{ .name = "doctor", .help = "report the health of makac and its packages" };

var root_cmd = ap.Command{
    .name = "makac",
    .flags = &.{version_flag},
    .commands = &.{ &init_cmd, &run_cmd, &fetch_cmd, &doctor_cmd },
};

// ------------------------------------------------------------- stdio -------

fn out(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch {
        std.Io.File.stdout().writeStreamingAll(io, fmt) catch {};
        return;
    };
    std.Io.File.stdout().writeStreamingAll(io, s) catch {};
}

fn err(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stderr().writeStreamingAll(io, s) catch {};
}

/// Print an error to stderr; Lua-side errors already carry the "makac: "
/// prefix, don't repeat it.
fn reportError(io: std.Io, msg: []const u8) void {
    if (std.mem.startsWith(u8, msg, "makac:")) {
        err(io, "{s}\n", .{msg});
    } else {
        err(io, "makac: {s}\n", .{msg});
    }
}

fn getCwd(allocator: std.mem.Allocator, io: std.Io) ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
}

// ------------------------------------------------------------ dispatch -----

pub fn main(init: std.process.Init) u8 {
    const allocator = init.gpa;
    const io = init.io;
    const argv = init.minimal.args.vector;

    const args = allocator.alloc([]const u8, if (argv.len > 0) argv.len - 1 else 0) catch return 1;
    defer allocator.free(args);
    for (argv[1..], 0..) |a, i| args[i] = std.mem.span(a);

    var pe: ap.ParseError = .{};
    const res = ap.parseArgs(allocator, &root_cmd, args, &pe) catch {
        err(io, "makac: failed to parse arguments\n", .{});
        err(io, "{s}", .{USAGE});
        return 1;
    };
    defer ap.deleteParseResult(allocator, res);

    const pc = ap.lastCommand(res) orelse {
        err(io, "{s}", .{USAGE});
        return 1;
    };

    if (std.mem.eql(u8, pc.source.name, "makac")) {
        // `makac --version` short-circuits everything else.
        if (pc.flags.get("version") != null) {
            out(io, "{s}\n", .{version.version});
            return 0;
        }
        // `makac <workflow> [args...]` — the implicit form.
        if (ap.findArgs(res)) |pargs| {
            if (pargs.value.len > 0) {
                return runScript(allocator, io, pargs.value[0], pargs.value[1..]);
            }
        }
        err(io, "{s}", .{USAGE});
        return 1;
    }

    if (std.mem.eql(u8, pc.source.name, "init")) {
        const pargs = ap.findArgs(res);
        if (pargs == null or pargs.?.value.len != 1) {
            err(io, "makac: init takes exactly one <path> argument\n", .{});
            err(io, "{s}", .{USAGE});
            return 1;
        }
        const path = pargs.?.value[0];
        dd.init(allocator, io, path) catch |e| {
            switch (e) {
                error.ProjectFileFailure => err(
                    io,
                    "makac: init: created the data directory but could not create 'makac_project.lua' next to it\n",
                    .{},
                ),
                error.MkdirFailure, error.OutOfMemory => err(
                    io,
                    "makac: init: failed to create data directory at '{s}'\n",
                    .{path},
                ),
            }
            return 1;
        };
        out(io, "makac: initialized data directory at {s}\n", .{path});
        // design/luacats.md: the data dir was just created, so install the
        // LuaLS stub and .luarc.json here too (best-effort).
        installLualsForPath(allocator, io, path);
        return 0;
    }

    if (std.mem.eql(u8, pc.source.name, "run")) {
        const pargs = ap.findArgs(res);
        if (pargs == null or pargs.?.value.len < 1) {
            err(io, "makac: run takes a <workflow> argument\n", .{});
            err(io, "{s}", .{USAGE});
            return 1;
        }
        return runScript(allocator, io, pargs.?.value[0], pargs.?.value[1..]);
    }

    if (std.mem.eql(u8, pc.source.name, "fetch")) {
        return fetch(allocator, io);
    }

    if (std.mem.eql(u8, pc.source.name, "doctor")) {
        const pargs = ap.findArgs(res);
        return doctor(allocator, io, if (pargs) |p| p.value else null);
    }

    err(io, "{s}", .{USAGE});
    return 1;
}

/// `makac fetch` — fetch every package listed in `<project root>/makac_project.lua`.
/// The project file lives beside the data directory, not inside it. The fetch
/// driver itself is the prelude's `makac.fetch_all` (fetchers are Lua
/// functions); this only resolves the data directory and runs it.
fn fetch(allocator: std.mem.Allocator, io: std.Io) u8 {
    const cwd = getCwd(allocator, io) catch {
        err(io, "makac: cannot determine working directory\n", .{});
        return 1;
    };
    defer allocator.free(cwd);

    const rr = dd.resolve(allocator, io, cwd) catch |e| {
        switch (e) {
            error.MkdirFailure => err(io, "makac: found project root but failed to create '.makac' data directory\n", .{}),
            error.ProjectFileFailure => err(io, "makac: found project root but failed to create 'makac_project.lua'\n", .{}),
            error.OutOfMemory => err(io, "makac: out of memory\n", .{}),
        }
        return 1;
    };
    const data_dir = switch (rr) {
        .none => {
            err(io, "makac: could not determine the root of the project (no '.makac' or '.git' found)\n", .{});
            err(io, "makac: initialize the data directory with: makac init <path>\n", .{});
            return 1;
        },
        .found, .created_at_git => |d| d,
    };
    defer allocator.free(data_dir);

    const project_file = dd.projectFilePath(allocator, data_dir) catch {
        err(io, "makac: out of memory\n", .{});
        return 1;
    };
    defer allocator.free(project_file);

    if (!fileExists(io, project_file)) {
        out(io, "makac: no makac_project.lua found.\n\n", .{});
        out(io, "The project file for this project lives at:\n  {s}\n", .{project_file});
        out(io, "{s}", .{FETCH_ADVICE});
        return 0;
    }

    return fetchInVm(allocator, io, data_dir);
}

/// Help text shown when `makac fetch` runs without a project file (a plain
/// string: no format specifiers are interpreted inside it).
const FETCH_ADVICE =
    \\Create it (a Lua file that MUST return a table), e.g.:
    \\
    \\  -- makac_project.lua
    \\  return {
    \\    inputs = {
    \\      -- the key is a local label for the fetch instruction
    \\      qemu = {
    \\        fetcher = "fetchgit",     -- built-in fetchers: "fetchurl", "fetchgit", "filesystem"
    \\        with = {                  -- arguments for the fetcher
    \\          url = "https://github.com/user/some-repo.git",
    \\          rev = "main",
    \\        },
    \\      },
    \\    },
    \\    -- wire an alias to an input label; the alias is what workflows and
    \\    -- packages use: 'qemu:<action>' in a step's uses field,
    \\    -- require("pkgs/qemu/...")
    \\    packages = { qemu = "qemu" },
    \\  }
    \\
    \\Then run 'makac fetch' again.
    \\
;

fn fetchInVm(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) u8 {
    const vm = vm_mod.VM.new(allocator, io, .{
        .data_dir = data_dir,
        .project_root = std.fs.path.dirname(data_dir),
    }) catch {
        err(io, "makac: failed to create Lua VM\n", .{});
        return 1;
    };
    defer vm.deinit();

    vm.runString("makac.fetch_all()", "@fetch") catch {
        reportError(io, vm.lastError());
        return 1;
    };
    // design/luacats.md: install/refresh the LuaLS stubs (best-effort).
    _ = installLuals(io, vm);
    return 0;
}

/// `makac doctor [name...]` — run the base + package health checks (the
/// prelude's `makac._doctor`), printing the report to stdout. It returns the
/// number of error findings; the CLI exits non-zero when > 0 (a failing check
/// is data, not an exception).
fn doctor(
    allocator: std.mem.Allocator,
    io: std.Io,
    pargs: ?[]const []const u8,
) u8 {
    // Base checks run with or without a project; package checks need one.
    var data_dir: []const u8 = "";
    var data_owned: ?[]u8 = null;
    defer if (data_owned) |d| allocator.free(d);

    if (getCwd(allocator, io)) |cwd| {
        defer allocator.free(cwd);
        if (dd.resolve(allocator, io, cwd) catch null) |r| switch (r) {
            .none => {},
            .found, .created_at_git => |d| {
                data_owned = d;
                data_dir = d;
            },
        };
    } else |_| {}

    const vm = vm_mod.VM.new(allocator, io, .{
        .data_dir = data_dir,
        .project_root = if (data_dir.len > 0) std.fs.path.dirname(data_dir) else null,
    }) catch {
        err(io, "makac: failed to create Lua VM\n", .{});
        return 1;
    };
    defer vm.deinit();

    const names = joinNames(allocator, pargs) catch {
        err(io, "makac: out of memory\n", .{});
        return 1;
    };
    defer allocator.free(names);

    const n = vm.callStringInt("makac._doctor", names) catch {
        reportError(io, vm.lastError());
        return 1;
    };
    if (n == null) {
        err(io, "makac: internal error: makac._doctor is missing\n", .{});
        return 1;
    }
    if (n.? > 0) return 1;
    return 0;
}

fn joinNames(allocator: std.mem.Allocator, pargs: ?[]const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    if (pargs) |args| {
        for (args, 0..) |a, i| {
            if (i > 0) try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, a);
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Run the prelude's `makac._luals_setup` for an already-created VM (no-op
/// when the VM has no data directory). Best-effort: it swallows its own
/// runtime errors, so a non-empty error here is a makac bug.
fn installLuals(io: std.Io, vm: *vm_mod.VM) bool {
    const called = vm.callNamed("makac._luals_setup") catch {
        err(io, "makac: warning: LuaLS stub install failed: {s}\n", .{vm.lastError()});
        return false;
    };
    if (!called) {
        err(io, "makac: warning: LuaLS stub install skipped (no makac._luals_setup)\n", .{});
        return false;
    }
    return true;
}

/// `makac init`: install the LuaLS stub for the project just created. `path`
/// is the CLI argument (``<dir>`` or an explicit ``…/.makac``).
fn installLualsForPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) void {
    var target: []const u8 = path;
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);
    if (!std.mem.endsWith(u8, path, ".makac")) {
        owned = std.fs.path.join(allocator, &.{ path, ".makac" }) catch return;
        target = owned.?;
    }
    const vm = vm_mod.VM.new(allocator, io, .{ .data_dir = target }) catch return;
    defer vm.deinit();
    _ = installLuals(io, vm);
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return true;
}

/// Resolve the data directory from the CWD and run the workflow. Outside a
/// project the script simply runs data-dir-less: PROJECT_DIR is left nil.
fn runScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    script: []const u8,
    script_args: []const []const u8,
) u8 {
    const cwd = getCwd(allocator, io) catch {
        err(io, "makac: cannot determine working directory\n", .{});
        return 1;
    };
    defer allocator.free(cwd);

    const rr = dd.resolve(allocator, io, cwd) catch {
        err(io, "makac: warning: could not prepare a '.makac' data directory; running without one\n", .{});
        return runScriptInVm(allocator, io, script, script_args, "", null);
    };
    switch (rr) {
        .none => return runScriptInVm(allocator, io, script, script_args, "", null),
        .found, .created_at_git => |d| {
            defer allocator.free(d);
            const root = std.fs.path.dirname(d);
            return runScriptInVm(allocator, io, script, script_args, d, root);
        },
    }
}

fn runScriptInVm(
    allocator: std.mem.Allocator,
    io: std.Io,
    script: []const u8,
    script_args: []const []const u8,
    data_dir: []const u8,
    project_root: ?[]const u8,
) u8 {
    const vm = vm_mod.VM.new(allocator, io, .{
        .data_dir = data_dir,
        .project_root = project_root,
    }) catch {
        err(io, "makac: failed to create Lua VM\n", .{});
        return 1;
    };
    defer vm.deinit();

    // Load fetched packages before evaluating the workflow: their
    // actions/fetchers join the registries as '<alias>:<name>' and their
    // lib/ becomes require-able via 'pkgs/<alias>/...'. Nothing fetched is
    // skipped silently — fetching is the explicit 'makac fetch' step.
    if (data_dir.len > 0) {
        vm.runString("makac.load_packages()", "@load_packages") catch {
            reportError(io, vm.lastError());
            return 1;
        };
    }

    vm.runFile(script, script_args) catch {
        reportError(io, vm.lastError());
        return 1;
    };
    // design/luacats.md: install/refresh the stub + package aliases (best-effort).
    _ = installLuals(io, vm);
    return 0;
}

// Zig 0.16 only emits `test` blocks from the root source file plus files
// referenced from a test block — plain runtime imports are not enough. Pull
// every module in here so `zig build test` actually runs the whole suite.
test {
    _ = @import("argparse.zig");
    _ = @import("datadir.zig");
    _ = @import("downloader.zig");
    _ = @import("lua.zig");
    _ = @import("qmp.zig");
    _ = @import("ssh.zig");
    _ = @import("subprocess.zig");
    _ = @import("version.zig");
    _ = @import("vm.zig");
    _ = @import("vm/dir.zig");
    _ = @import("vm/env.zig");
    _ = @import("vm/exec.zig");
    _ = @import("vm/fetch.zig");
    _ = @import("vm/fs.zig");
    _ = @import("vm/json.zig");
    _ = @import("vm/luals.zig");
    _ = @import("vm/path.zig");
    _ = @import("vm/proc.zig");
    _ = @import("vm/qmp.zig");
    _ = @import("vm/random.zig");
    _ = @import("vm/ssh_target.zig");
    _ = @import("vm/register.zig");
    _ = @import("vm/spawn.zig");
    _ = @import("vm/time.zig");
    _ = @import("vm/version.zig");
}
