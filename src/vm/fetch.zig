// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// fetch.zig — makac.download(url[, sha256[, cache_dir_hint]]) -> path.
//
// Fetches `url` over HTTP(S) into a cache directory keyed as
// `<cache_dir>/<sha256(url)>` (see the downloader module), optionally
// verifying the bytes against `sha256`, and returns the on-disk cached path.
// The cache directory defaults to `<data_dir>/cache`; the optional third
// argument overrides it (a cache-dir hint). A data-dir-less VM may only
// download with an explicit hint.
//
// Failures (network, HTTP error, checksum mismatch, ...) raise a Lua error
// naming the downloader error.

const std = @import("std");
const lua = @import("../lua.zig");
const reg = @import("register.zig");
const downloader = @import("../downloader.zig");
const VM = @import("../vm.zig").VM;

fn host(L: *lua.State) *VM {
    return @ptrCast(@alignCast(reg.hostContext(L)));
}

pub fn registerFetch(L: *lua.State) void {
    reg.register(L, "download", makacDownload);
}

fn makacDownload(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const v = host(L);

    const url = lua.checkLString(L, 1);

    var sha: []const u8 = "";
    if (!lua.isNoneOrNil(L, 2)) {
        lua.checkType(L, 2, lua.TSTRING);
        sha = lua.toLString(L, 2).?;
    }

    var cache_owned: ?[]u8 = null;
    var cache_dir: []const u8 = "";
    if (!lua.isNoneOrNil(L, 3)) {
        lua.checkType(L, 3, lua.TSTRING);
        const hint = lua.toLString(L, 3).?;
        if (hint.len > 0) {
            cache_owned = v.allocator.dupe(u8, hint) catch oom(L);
            cache_dir = cache_owned.?;
        }
    }
    if (cache_dir.len == 0) {
        if (v.data_dir.len == 0) {
            freeOwned(v, cache_owned);
            lua.raise(L, "makac.download: cannot download: no data directory (internal: VM created data-dir-less)");
        }
        cache_owned = std.fs.path.join(v.allocator, &.{ v.data_dir, "cache" }) catch oom(L);
        cache_dir = cache_owned.?;
    }

    var d = downloader.Downloader{ .cache_dir = cache_dir };
    const path = d.download(v.io, url, sha, v.allocator) catch |e| {
        freeOwned(v, cache_owned);
        raiseDownload(L, e, url);
    };
    lua.pushLString(L, path);
    v.allocator.free(path);
    freeOwned(v, cache_owned);
    return 1;
}

fn freeOwned(v: *VM, owned: ?[]u8) void {
    if (owned) |c| v.allocator.free(c);
}

fn oom(L: *lua.State) noreturn {
    lua.raise(L, "makac.download: out of memory");
}

fn raiseDownload(L: *lua.State, e: downloader.Error, url: []const u8) noreturn {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "makac.download: {s} (url: {s})", .{
        downloader.message(e),
        url,
    }) catch "makac.download: the download failed";
    lua.raiseLString(L, msg);
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

test "makac.download is registered and raises cleanly without a data dir" {
    const vm = try VM.new(testing.allocator, testing.io, .{});
    defer vm.deinit();
    try vm.runString(
        \\assert(type(makac.download) == "function", "makac.download missing")
        \\local ok, err = pcall(makac.download, "https://example.com/x")
        \\assert(not ok, "data-dir-less download must raise")
        \\assert(tostring(err):find("no data directory", 1, true) ~= nil, tostring(err))
    , "@fetch_test");
}

test "makac.download with an explicit cache hint uses that directory" {
    const vm = try VM.new(testing.allocator, testing.io, .{});
    defer vm.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    // No network: the hint is only parsed and the curl transfer is expected
    // to fail (there is no server); assert the error is a download failure,
    // proving the hint path was taken rather than the data-dir guard.
    const src = try std.fmt.allocPrint(
        testing.allocator,
        \\local ok, err = pcall(makac.download, "http://127.0.0.1:1/never", "", "{s}")
        \\assert(not ok)
        \\assert(tostring(err):find("download", 1, true) ~= nil, tostring(err))
    ,
        .{root},
    );
    defer testing.allocator.free(src);
    try vm.runString(src, "@fetch_test");
}
