// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// downloader.zig — URL-keyed file cache. Downloads a URL, optionally verifies
// a SHA256 checksum, caches the file under `<cache_dir>/<sha256(url)>`, and
// returns the on-disk path.
//
// The package never implements HTTP or hashing itself:
//   * downloads shell out to the `curl` CLI (`curlCliDownload`) — the curl
//     binary bundles its own TLS/zlib deps, so this is the minimum-dependency
//     way to make an HTTP request (like `git`/`tar`);
//   * checksums/hash keys use std.crypto.hash.sha2.Sha256.
//
// Note:
//   * the body streams straight to a temp file (curl -o), never into parent
//     RAM;
//   * there is no busy-spin: curl owns the transfer, bounded by --connect-
//     timeout/--speed-limit/--speed-time.
//
// The transfer is a `download_fn` seam so unit tests inject a fake downloader
// and exercise the cache/hash/rename logic with no network.

const std = @import("std");
const subprocess = @import("subprocess.zig");

const c_alloc = std.heap.c_allocator;

/// Errors the downloader can report; `message` renders them for users.
pub const Error = error{
    BadArguments,
    MkdirFailure,
    WriteFailure,
    ChecksumMismatch,
    DownloadFailure,
    OutOfMemory,
};

/// Human-readable message for a downloader error (used by the Lua binding).
pub fn message(e: Error) []const u8 {
    return switch (e) {
        error.BadArguments => "bad arguments (the URL is empty)",
        error.MkdirFailure => "could not create the cache directory",
        error.WriteFailure => "could not write the downloaded file",
        error.ChecksumMismatch => "checksum mismatch",
        error.DownloadFailure => "the download failed (network, HTTP status, or curl not found)",
        error.OutOfMemory => "out of memory",
    };
}

// ------------------------------------------------------ transfer bounds ----

/// Bound the CONNECT phase: an unreachable or blackholed server aborts within
/// this many seconds. curl has no default connect timeout.
pub const CONNECT_TIMEOUT_S = "10";
/// Stall detection: abort when the transfer delivers less than
/// STALL_SPEED_LIMIT_B bytes/s for STALL_TIME_S consecutive seconds.
pub const STALL_SPEED_LIMIT_B = "1024";
pub const STALL_TIME_S = "30";

/// The transfer seam. Given a `url`, write the response body into the file at
/// `dest_path`, creating or truncating it. On failure the file's contents are
/// unspecified (the caller removes it).
pub const DownloadFn = *const fn (io: std.Io, url: []const u8, dest_path: []const u8) Error!void;

/// Default seam: stream the body to `dest_path` with the `curl` CLI. The body
/// never touches the parent's address space.
pub fn curlCliDownload(io: std.Io, url: []const u8, dest_path: []const u8) Error!void {
    _ = io;
    const argv = [_][]const u8{
        "curl",              "-fsSL",
        "--proto",           "=http,https",
        "--proto-redir",     "=http,https",
        "--connect-timeout", CONNECT_TIMEOUT_S,
        "--speed-limit",     STALL_SPEED_LIMIT_B,
        "--speed-time",      STALL_TIME_S,
        "-o",                dest_path,
        "--",                url,
    };
    const res = subprocess.run(&argv, .{
        .capture_stdout = false,
        .capture_stderr = true,
        .allocator = c_alloc,
    }) catch return error.DownloadFailure;
    defer c_alloc.free(res.stdout);
    defer c_alloc.free(res.stderr);
    if (res.code != 0) return error.DownloadFailure;
}

// ------------------------------------------------------------- cache -------

/// SHA256 hex (lowercase) of a URL — the downloader's cache key.
pub fn urlCacheKey(allocator: std.mem.Allocator, url: []const u8) Error![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex) catch error.OutOfMemory;
}

pub const Downloader = struct {
    /// Cache directory shared across all fetched files.
    cache_dir: []const u8,
    /// Transfer seam; tests repoint this at a stub.
    download_impl: DownloadFn = curlCliDownload,

    /// `<cache_dir>/<sha256hex(url)>` (caller owns the returned path).
    pub fn getCachedPath(
        self: *const Downloader,
        allocator: std.mem.Allocator,
        url: []const u8,
    ) Error![]u8 {
        const key = try urlCacheKey(allocator, url);
        defer allocator.free(key);
        return std.fs.path.join(allocator, &.{ self.cache_dir, key }) catch error.OutOfMemory;
    }

    /// Pure existence check: an empty URL is never cached, and a missing entry
    /// creates nothing.
    pub fn isCached(
        self: *const Downloader,
        io: std.Io,
        allocator: std.mem.Allocator,
        url: []const u8,
    ) bool {
        if (url.len == 0) return false;
        const p = self.getCachedPath(allocator, url) catch return false;
        defer allocator.free(p);
        return exists(io, p);
    }

    /// Return the path of the cached file for `url`: a cache hit is served
    /// directly (re-verified when a checksum is given), otherwise the URL is
    /// fetched via the seam, verified, and atomically renamed into place. The
    /// returned path is owned by the caller.
    pub fn download(
        self: *const Downloader,
        io: std.Io,
        url: []const u8,
        expected_sha256: []const u8,
        allocator: std.mem.Allocator,
    ) Error![]u8 {
        if (url.len == 0) return error.BadArguments;

        var exp_buf: [256]u8 = undefined;
        const expected = lowerHex(&exp_buf, expected_sha256);

        const final_path = try self.getCachedPath(allocator, url);
        errdefer allocator.free(final_path);

        // Cache hit: reuse only when no checksum was given or the cached
        // contents verify. A mismatching entry is corrupt — drop it.
        if (exists(io, final_path)) {
            if (expected.len == 0 or fileMatchesSha256(io, final_path, expected)) {
                return final_path;
            }
            removeFile(io, final_path);
        }

        mkdirAll(io, self.cache_dir) catch return error.MkdirFailure;

        const tmp_path = std.fmt.allocPrint(allocator, "{s}.tmp", .{final_path}) catch
            return error.OutOfMemory;
        defer allocator.free(tmp_path);

        self.download_impl(io, url, tmp_path) catch |e| {
            removeFile(io, tmp_path);
            return e;
        };

        if (expected.len != 0 and !fileMatchesSha256(io, tmp_path, expected)) {
            removeFile(io, tmp_path);
            return error.ChecksumMismatch;
        }

        const cwd = std.Io.Dir.cwd();
        cwd.rename(tmp_path, cwd, final_path, io) catch {
            removeFile(io, tmp_path);
            return error.WriteFailure;
        };
        return final_path;
    }
};

// ---------------------------------------------------------- helpers --------

fn lowerHex(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return true;
}

fn removeFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn mkdirAll(io: std.Io, path: []const u8) !void {
    _ = try std.Io.Dir.cwd().createDirPath(io, path);
}

/// Lowercase SHA256 hex of the file at `path`, or null if it cannot be read.
fn fileSha256(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return null,
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex) catch null;
}

fn fileMatchesSha256(io: std.Io, path: []const u8, expected: []const u8) bool {
    var buf: [64]u8 = undefined;
    var alloc = std.heap.FixedBufferAllocator.init(&buf);
    const digest = fileSha256(io, alloc.allocator(), path) orelse return false;
    return std.mem.eql(u8, digest, expected);
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

// The seam cannot capture per-test state, so tests use package-level fields.
var fake_calls: usize = 0;
var fake_body: []const u8 = "";
var fake_fail: bool = false;

fn fakeDownload(io: std.Io, url: []const u8, dest_path: []const u8) Error!void {
    _ = url;
    fake_calls += 1;
    if (fake_fail) return error.DownloadFailure;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_path, .data = fake_body }) catch
        return error.DownloadFailure;
}

fn resetFake(payload: []const u8, fail: bool) void {
    fake_calls = 0;
    fake_body = payload;
    fake_fail = fail;
}

fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

test "downloader: cache key is sha256(url) and keying is pure" {
    const alloc = testing.allocator;
    var d = Downloader{ .cache_dir = "/tmp/makac-cache" };

    const key = try urlCacheKey(alloc, "https://example.com/x");
    defer alloc.free(key);
    try testing.expectEqualStrings(
        "54cef8f42f3f31ad349075022cd36ce1a378d039c1df7af45d61d693d9a35c6a",
        key,
    );

    const p = try d.getCachedPath(alloc, "https://example.com/x");
    defer alloc.free(p);
    const expect_p = try std.fmt.allocPrint(alloc, "/tmp/makac-cache/{s}", .{key});
    defer alloc.free(expect_p);
    try testing.expectEqualStrings(expect_p, p);

    // empty URL still hashes deterministically
    const ek = try urlCacheKey(alloc, "");
    defer alloc.free(ek);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ek,
    );

    // different URLs never share a slot
    const k2 = try urlCacheKey(alloc, "https://example.com/y");
    defer alloc.free(k2);
    try testing.expect(!std.mem.eql(u8, key, k2));
}

test "downloader: isCached is pure and false for empty/missing" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const cache = try std.fs.path.join(alloc, &.{ root, "cache-does-not-exist" });
    defer alloc.free(cache);
    const d = Downloader{ .cache_dir = cache };

    try testing.expect(!d.isCached(io, alloc, ""));
    try testing.expect(!d.isCached(io, alloc, "https://example.com/x"));
    try testing.expect(!exists(io, cache)); // pure: nothing created
}

test "downloader: no-checksum fetch caches under the key; second is a hit" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const url = "https://example.com/x";
    resetFake("some bytes, unverified\n", false);
    var d = Downloader{ .cache_dir = root, .download_impl = fakeDownload };

    const p1 = try d.download(io, url, "", alloc);
    defer alloc.free(p1);
    try testing.expectEqual(@as(usize, 1), fake_calls);

    const key = try urlCacheKey(alloc, url);
    defer alloc.free(key);
    const expect = try std.fs.path.join(alloc, &.{ root, key });
    defer alloc.free(expect);
    try testing.expectEqualStrings(expect, p1);
    try testing.expect(exists(io, p1));

    const p2 = try d.download(io, url, "", alloc);
    defer alloc.free(p2);
    try testing.expectEqualStrings(p1, p2);
    try testing.expectEqual(@as(usize, 1), fake_calls); // served from cache
}

test "downloader: verify-on-hit (correct entry served, no transfer)" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const url = "https://example.com/verified";
    const body = "VERIFIED-BODY";
    const sha = try sha256Hex(alloc, body);
    defer alloc.free(sha);

    var d = Downloader{ .cache_dir = root, .download_impl = fakeDownload };
    const p = try d.getCachedPath(alloc, url);
    defer alloc.free(p);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = body });

    resetFake("SHOULD-NOT-BE-SERVED", false);
    const hit = try d.download(io, url, sha, alloc);
    defer alloc.free(hit);
    try testing.expectEqualStrings(p, hit);
    try testing.expectEqual(@as(usize, 0), fake_calls); // no transfer on a verified hit
}

test "downloader: corrupt cache entry dropped and refetched" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const url = "https://example.com/refetch";
    const good = "REFETCH-ME";
    const sha = try sha256Hex(alloc, good);
    defer alloc.free(sha);

    var d = Downloader{ .cache_dir = root, .download_impl = fakeDownload };
    const cached = try d.getCachedPath(alloc, url);
    defer alloc.free(cached);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cached, .data = "CORRUPTED" });

    resetFake(good, false);
    const got = try d.download(io, url, sha, alloc);
    defer alloc.free(got);
    try testing.expectEqual(@as(usize, 1), fake_calls); // corrupt entry dropped, refetched
    const body = try readAll(io, alloc, got);
    defer alloc.free(body);
    try testing.expectEqualStrings(good, body);
}

test "downloader: checksum mismatch errors and caches nothing" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const url = "https://example.com/mismatch";
    const sha = try sha256Hex(alloc, "expected-content");
    defer alloc.free(sha);

    resetFake("actual-content", false);
    var d = Downloader{ .cache_dir = root, .download_impl = fakeDownload };

    try testing.expectError(error.ChecksumMismatch, d.download(io, url, sha, alloc));
    try testing.expectEqual(@as(usize, 1), fake_calls);

    const cached = try d.getCachedPath(alloc, url);
    defer alloc.free(cached);
    try testing.expect(!exists(io, cached)); // final never placed
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{cached});
    defer alloc.free(tmp_path);
    try testing.expect(!exists(io, tmp_path)); // temp cleaned up
}

test "downloader: empty url is BadArguments and never invokes the seam" {
    const io = testing.io;
    const alloc = testing.allocator;

    resetFake("nope", false);
    const d = Downloader{ .cache_dir = "/tmp/makac-cache-nope", .download_impl = fakeDownload };
    try testing.expectError(error.BadArguments, d.download(io, "", "", alloc));
    try testing.expectEqual(@as(usize, 0), fake_calls);
}

test "downloader: download failure leaves no temp file and no cache dir entry" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    resetFake("x", true); // seam fails after (notionally) opening the file
    var d = Downloader{ .cache_dir = root, .download_impl = fakeDownload };
    try testing.expectError(error.DownloadFailure, d.download(io, "https://example.com/dead", "", alloc));

    const cached = try d.getCachedPath(alloc, "https://example.com/dead");
    defer alloc.free(cached);
    try testing.expect(!exists(io, cached));
}

fn readAll(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = f.readStreaming(io, &.{&chunk}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        try buf.appendSlice(alloc, chunk[0..n]);
    }
    return buf.toOwnedSlice(alloc);
}
