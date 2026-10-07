// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Stock Lua 5.4, built from the vendored upstream C sources, compiled
    // INTO the executable module: one binary, libc linked, headers visible
    // to @cImport in our sources.
    const lua_dep = b.dependency("lua", .{});
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.link_libc = true;
    exe_mod.addCSourceFiles(.{
        .root = lua_dep.path("src"),
        .files = &lua_sources,
        .flags = &.{ "-std=c99", "-O2" },
    });
    exe_mod.addIncludePath(lua_dep.path("src"));
    // POSIX feature bits lua expects (popen, ...)
    exe_mod.addCMacro("_DEFAULT_SOURCE", "");

    const exe = b.addExecutable(.{ .name = "makac", .root_module = exe_mod });
    b.installArtifact(exe);

    // unit tests
    const tests = b.addTest(.{ .root_module = exe_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "zig unit tests");
    test_step.dependOn(&run_tests.step);
}

// All of lua's src/*.c except the two with main() (lua.c, luac.c) and
// onelua.c — the classic embedder list.
const lua_sources = .{
    "lauxlib.c", "lbaselib.c", "lcorolib.c", "ldblib.c",   "liolib.c",
    "lmathlib.c", "loadlib.c",  "loslib.c",   "lstrlib.c", "ltablib.c",
    "lutf8lib.c", "lapi.c",     "lcode.c",    "lctype.c",  "ldebug.c",
    "ldo.c",      "ldump.c",    "lfunc.c",    "lgc.c",     "llex.c",
    "linit.c", // <-- luaL_openlibs lives here; omit it and you link-fail
    "lmem.c",     "lobject.c",  "lopcodes.c", "lparser.c", "lstate.c",
    "lstring.c",  "ltable.c",   "ltm.c",      "lundump.c", "lvm.c",
    "lzio.c",
};
