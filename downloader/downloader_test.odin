// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package downloader

import "base:runtime"
import "core:mem"
import "core:os"
import "core:sync"
import "core:testing"

// Package-level alias so test procs can take the bare `^T` signature, matching
// the convention used across the other packages' test files.
T :: testing.T

// The cache is keyed by the SHA256 of the URL, so the expected cache paths
// below are fixed constants (sha256 -n of the URL strings).
TEST_URL :: "https://example.com/x"
TEST_URL_KEY :: "54cef8f42f3f31ad349075022cd36ce1a378d039c1df7af45d61d693d9a35c6a" // sha256(TEST_URL)
EMPTY_URL_KEY :: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" // sha256("")

// ---------------------------------------------------------------------------
// Cache-key core (network-free)
// ---------------------------------------------------------------------------

/// The cache path is `<cacheDir>/<sha256hex(url)>`, and nothing else.
@(test)
test_get_cached_path :: proc(t: ^T) {
	d := new_downloader("/tmp/makac-cache")
	defer free(d)

	path := GetCachedPath(d, TEST_URL)
	defer delete(path, context.allocator)

	testing.expect_value(t, path, "/tmp/makac-cache/" + TEST_URL_KEY)
}

/// An empty URL still hashes to a well-defined key (sha256 of the empty
/// string), so `GetCachedPath` always produces a complete path.
@(test)
test_get_cached_path_empty_url :: proc(t: ^T) {
	d := new_downloader("/tmp/makac-cache")
	defer free(d)

	path := GetCachedPath(d, "")
	defer delete(path, context.allocator)

	testing.expect_value(t, path, "/tmp/makac-cache/" + EMPTY_URL_KEY)
}

/// An empty URL is always "not cached" (it is not fetchable).
@(test)
test_is_cached_empty_is_false :: proc(t: ^T) {
	d := new_downloader("/tmp/makac-cache-does-not-exist")
	defer free(d)

	testing.expect(t, !IsCached(d, ""), "empty URL must never be a cache hit")
}

/// The cache-key core performs no writes: `GetCachedPath` is pure string
/// building and `IsCached` on a missing entry must not create anything.
@(test)
test_is_cached_missing_does_not_create :: proc(t: ^T) {
	dir := "/tmp/makac-cache-missing-should-not-exist"
	d := new_downloader(dir)
	defer free(d)

	testing.expect(t, !IsCached(d, TEST_URL), "missing entry must not be a cache hit")
	testing.expect(t, !os.exists(dir), "IsCached must not create the cache directory")
}

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

/// The cache-key core must make no net allocation: every value it creates is
/// freed before it returns, so running it under a tracking allocator leaves an
/// empty allocation map.
@(test)
test_no_leaks :: proc(t: ^T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	d := new_downloader("/tmp/makac-cache-leak-test")

	path := GetCachedPath(d, TEST_URL)
	delete(path, context.allocator)

	_ = IsCached(d, TEST_URL)

	free(d)

	testing.expectf(
		t,
		len(track.allocation_map) == 0,
		"leaked %d allocations",
		len(track.allocation_map),
	)
}

// ---------------------------------------------------------------------------
// Download (network-free, driven through the `download_impl` seam)
// ---------------------------------------------------------------------------

// The seam is a package-level proc (a `download_fn` cannot capture per-test
// state), so the stub serves bytes from package-level fields guarded by a
// mutex. This mirrors the `ssh` package repointing `SSH_BIN`/`SCP_BIN` and
// serialising the stub-using tests on their own mutex.
_stub_payload: []byte = nil
_stub_err: Error = .None
_stub_calls := 0
stub_mutex: sync.Mutex = sync.Mutex{}

/// `_stub_download` is the test `download_fn`: it records one call, copies the
/// canned `_stub_payload` into `sink.data`, and returns `_stub_err`. It assumes
/// the caller already holds `stub_mutex`.
_stub_download :: proc(_url: string, sink: ^byte_sink, alloc: runtime.Allocator) -> Error {
	_stub_calls += 1
	n := len(_stub_payload)
	if n > 0 {
		grown, gerr := mem.resize_bytes(sink.data, n, mem.DEFAULT_ALIGNMENT, alloc)
		if gerr == nil {
			mem.copy(cast(rawptr)&grown[0], cast(rawptr)&_stub_payload[0], n)
			sink.data = grown
		}
	}
	return _stub_err
}

/// `_reset_pool` repoints the seam to serve `payload` and return `err`, copying
/// `payload` so later test edits cannot corrupt it. Assumes `stub_mutex` is
/// already held by the caller.
///
/// The caller is responsible for freeing `_stub_payload` (see the stub-using
/// tests, which `delete` it before they return); the tracking allocator frees
/// any leaked buffer at the end of a test, so a later test must not free it.
_reset_pool :: proc(t: ^T, payload: string, err: Error) {
	n := len(payload)
	_stub_payload = make([]byte, n, context.allocator)
	i := 0
	for i < n {
		_stub_payload[i] = payload[i]
		i += 1
	}
	_stub_err = err
	_stub_calls = 0
}

/// `_seed_cache` writes `payload` to the cache slot for `url`, so `IsCached`
/// reports a hit without any transfer. Assumes `stub_mutex` is held.
_seed_cache :: proc(t: ^T, d: ^Downloader, url, payload: string) {
	_ = os.mkdir_all(d.cacheDir, os.perm_number(0o755))
	full := GetCachedPath(d, url)
	werr := os.write_entire_file_from_string(full, payload)
	testing.expect(t, werr == nil, "failed to seed cache file")
	delete(full, context.allocator)
}

/// `_dir_is_empty` asserts the directory has no entries (used to prove the temp
/// file was cleaned up on a failure path).
_dir_is_empty :: proc(t: ^T, dir: string) {
	files, ferr := os.read_all_directory_by_path(dir, context.allocator)
	testing.expectf(t, ferr == nil, "read dir err: {}", ferr)
	testing.expectf(t, len(files) == 0, "expected empty dir, found %d entries", len(files))
	delete(files, context.allocator)
}

_make_temp_cache :: proc(t: ^T, pattern: string) -> string {
	dir, derr := os.make_directory_temp("", pattern, context.allocator)
	testing.expectf(t, derr == nil, "make temp dir err: {}", derr)
	return dir
}

/// An empty `url` is rejected with `.Bad_Arguments`: no transfer and no
/// filesystem work are performed.
@(test)
test_download_empty_url_is_bad_arguments :: proc(t: ^T) {
	sync.lock(&stub_mutex)
	defer sync.unlock(&stub_mutex)

	dir := _make_temp_cache(t, "makac_dl_emptyurl_*")
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	d := new_downloader(dir)
	defer free(d)

	_reset_pool(t, "should-not-be-served", .None)
	defer delete(_stub_payload, context.allocator)
	d.download_impl = _stub_download

	path, err := Download(d, "")
	testing.expect(t, err == .Bad_Arguments, "empty url must be .Bad_Arguments")
	testing.expect(t, path == "", "empty url must not return a path")
	testing.expect(t, _stub_calls == 0, "bad args must not invoke the seam")
}

/// The checksum is optional: with no `expected_sha256`, a fetch succeeds and
/// caches under the URL's key.
@(test)
test_download_no_checksum_ok :: proc(t: ^T) {
	sync.lock(&stub_mutex)
	defer sync.unlock(&stub_mutex)

	dir := _make_temp_cache(t, "makac_dl_nosha_*")
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	d := new_downloader(dir)
	defer free(d)

	payload: string = "some bytes, unverified\n"
	_reset_pool(t, payload, .None)
	defer delete(_stub_payload, context.allocator)
	d.download_impl = _stub_download

	path, err := Download(d, TEST_URL)
	testing.expect(t, err == .None, "unchecksummed fetch should succeed")
	testing.expect(t, _stub_calls == 1, "cache miss should invoke the seam once")

	expect := GetCachedPath(d, TEST_URL)
	testing.expect(t, path == expect, "returns the URL-keyed cached path")
	delete(expect, context.allocator)

	got, gerr := os.read_entire_file_from_path(path, context.allocator)
	testing.expectf(t, gerr == nil, "read back err: {}", gerr)
	testing.expect(t, string(got) == payload, "cached content matches the seam output")
	delete(got, context.allocator)

	testing.expect(t, IsCached(d, TEST_URL), "entry must be cached after the fetch")
	delete(path, context.allocator)
}

/// A cache hit returns the cached path and never touches the seam — both with
/// and without a checksum (here: with one).
@(test)
test_download_cache_hit_does_not_download :: proc(t: ^T) {
	sync.lock(&stub_mutex)
	defer sync.unlock(&stub_mutex)

	dir := _make_temp_cache(t, "makac_dl_hit_*")
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	d := new_downloader(dir)
	defer free(d)

	// "hello world\n" hashes to this value (see sha256sum).
	sum := "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447"
	_seed_cache(t, d, TEST_URL, "hello world\n")
	_reset_pool(t, "should-not-be-served", .None)
	defer delete(_stub_payload, context.allocator)
	d.download_impl = _stub_download

	path, err := Download(d, TEST_URL, sum)
	testing.expect(t, err == .None, "cache hit should succeed")
	expect := GetCachedPath(d, TEST_URL)
	testing.expect(t, path == expect, "cache hit returns the cached path")
	testing.expect(t, _stub_calls == 0, "cache hit must not invoke the seam")
	delete(path, context.allocator)
	delete(expect, context.allocator)
}

/// A cached entry that fails a requested checksum is corrupt/wrong: it is
/// dropped and the URL is fetched again, so the caller never receives bytes
/// that fail verification.
@(test)
test_download_corrupt_cache_redownloads :: proc(t: ^T) {
	sync.lock(&stub_mutex)
	defer sync.unlock(&stub_mutex)

	dir := _make_temp_cache(t, "makac_dl_corrupt_*")
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	d := new_downloader(dir)
	defer free(d)

	good: string = "hello world\n"
	sum := "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447" // sha256(good)
	_seed_cache(t, d, TEST_URL, "stale, wrong bytes")
	_reset_pool(t, good, .None)
	defer delete(_stub_payload, context.allocator)
	d.download_impl = _stub_download

	path, err := Download(d, TEST_URL, sum)
	testing.expect(t, err == .None, "redownload of a corrupt entry should succeed")
	testing.expect(t, _stub_calls == 1, "corrupt entry must trigger a refetch")

	got, gerr := os.read_entire_file_from_path(path, context.allocator)
	testing.expectf(t, gerr == nil, "read back err: {}", gerr)
	testing.expect(t, string(got) == good, "replaced content is the fresh download")
	delete(got, context.allocator)
	delete(path, context.allocator)
}

/// A cache miss transfers through the seam, verifies the checksum, and moves
/// the verified bytes into the URL-keyed slot; the entry is then a cache hit.
@(test)
test_download_caches_verified_content :: proc(t: ^T) {
	sync.lock(&stub_mutex)
	defer sync.unlock(&stub_mutex)

	dir := _make_temp_cache(t, "makac_dl_miss_*")
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	d := new_downloader(dir)
	defer free(d)

	payload: string = "hello world\n"
	sum := "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447"
	_reset_pool(t, payload, .None)
	defer delete(_stub_payload, context.allocator)
	d.download_impl = _stub_download

	path, err := Download(d, TEST_URL, sum)
	testing.expect(t, err == .None, "download+cache should succeed")
	testing.expect(t, _stub_calls == 1, "cache miss should invoke the seam once")

	expect := GetCachedPath(d, TEST_URL)
	testing.expect(t, path == expect, "returns the cached path")

	got, gerr := os.read_entire_file_from_path(path, context.allocator)
	testing.expectf(t, gerr == nil, "read back err: {}", gerr)
	testing.expect(t, string(got) == payload, "cached content matches the seam output")
	delete(got, context.allocator)
	delete(expect, context.allocator)

	testing.expect(t, IsCached(d, TEST_URL), "entry must be cached after a successful download")

	// A subsequent verified download is a hit: no second transfer.
	path2, err2 := Download(d, TEST_URL, sum)
	testing.expect(t, err2 == .None, "verified re-download is a cache hit")
	testing.expect(t, path2 == path, "same URL returns the same slot")
	testing.expect(t, _stub_calls == 1, "verified hit must not re-invoke the seam")
	delete(path2, context.allocator)

	delete(path, context.allocator)
}

/// A checksum mismatch on download removes the temp file, leaves no final
/// entry, and returns `.Checksum_Mismatch`.
@(test)
test_download_checksum_mismatch :: proc(t: ^T) {
	sync.lock(&stub_mutex)
	defer sync.unlock(&stub_mutex)

	dir := _make_temp_cache(t, "makac_dl_mismatch_*")
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	d := new_downloader(dir)
	defer free(d)

	// The seam serves "different bytes"; we ask for the hash of "hello world\n".
	ask := "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447"
	_reset_pool(t, "different bytes", .None)
	defer delete(_stub_payload, context.allocator)
	d.download_impl = _stub_download

	path, err := Download(d, TEST_URL, ask)
	testing.expect(t, err == .Checksum_Mismatch, "checksum mismatch must be .Checksum_Mismatch")
	testing.expect(t, _stub_calls == 1, "seam should have been invoked")
	testing.expect(t, path == "", "mismatch must not return a path")

	final := GetCachedPath(d, TEST_URL)
	testing.expect(t, !os.exists(final), "no final entry on mismatch")
	delete(final, context.allocator)
	_dir_is_empty(t, dir)
}

/// A seam failure propagates as `.Download_Failure` and leaves no entry behind.
@(test)
test_download_seam_failure :: proc(t: ^T) {
	sync.lock(&stub_mutex)
	defer sync.unlock(&stub_mutex)

	dir := _make_temp_cache(t, "makac_dl_fail_*")
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	d := new_downloader(dir)
	defer free(d)

	_reset_pool(t, "whatever", .Download_Failure)
	defer delete(_stub_payload, context.allocator)
	d.download_impl = _stub_download

	path, err := Download(d, TEST_URL)
	testing.expect(t, err == .Download_Failure, "seam failure must propagate as .Download_Failure")
	testing.expect(t, _stub_calls == 1, "seam should have been invoked")
	testing.expect(t, path == "", "failure must not return a path")
	_dir_is_empty(t, dir)
}

/// `Download` must make no net allocation of its own: every transient value is
/// freed before it returns, and the only caller-owned value (the returned path)
/// is freed by the caller. Run under a tracking allocator this leaves an empty
/// allocation map.
@(test)
test_download_no_leaks :: proc(t: ^T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	alloc := context.allocator

	sync.lock(&stub_mutex)
	defer sync.unlock(&stub_mutex)

	dir := _make_temp_cache(t, "makac_dl_leak_*")

	d := new_downloader(dir)

	payload: string = "hello world\n"
	sum := "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447"
	_reset_pool(t, payload, .None)
	d.download_impl = _stub_download

	path, err := Download(d, TEST_URL, sum)
	testing.expect(t, err == .None, "download+cache should succeed")
	want := GetCachedPath(d, TEST_URL)
	testing.expect(t, path == want, "returns the cached path")
	delete(want, alloc)

	// Free every caller-owned allocation explicitly, before the leak check
	// (defers run after the check, so they must not carry the tracked frees).
	delete(path, alloc)
	delete(_stub_payload, alloc)
	_stub_payload = nil
	_stub_err = .None
	_stub_calls = 0
	_ = os.remove_all(dir)
	delete(dir, alloc)
	free(d)

	testing.expectf(
		t,
		len(track.allocation_map) == 0,
		"leaked %d allocations",
		len(track.allocation_map),
	)
}

/// Exercises the *real* `curl_cli_download` path over HTTPS (redirects, TLS,
/// and checksum verification) end to end.
///
/// It is guarded behind the `MAKAC_REAL_WORLD` environment variable so the
/// default `odin test` run stays hermetic — set `MAKAC_REAL_WORLD=1` to run it.
@(test)
test_download_real_world_https :: proc(t: ^T) {
	key, _ := os.lookup_env("MAKAC_REAL_WORLD", context.allocator)
	if key == "" {
		// Networked test disabled by default; keep `odin test` hermetic.
		return
	}

	dir := _make_temp_cache(t, "makac_dl_real_*")
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	d := new_downloader(dir)
	defer free(d)

	// A small, versioned (content-stable) file from a well-known CDN.
	url := "https://cdn.jsdelivr.net/gh/python/cpython@v3.12.0/LICENSE"
	sum := "3b2f81fe21d181c499c59a256c8e1968455d6689d269aa85373bfb6af41da3bf"

	path, err := Download(d, url, sum)
	testing.expectf(t, err == .None, "real-world HTTPS download should succeed, got: {}", err)
	testing.expect(t, path != "", "real-world download should return a path")

	// The cached file must exist and hash to the expected digest (independent
	// re-hash, exercising core:crypto/hash rather than trusting Download).
	got, gerr := hash_file(path)
	testing.expectf(t, gerr == nil, "hash cached file err: {}", gerr)
	testing.expect(t, string(got) == sum, "downloaded content must hash to the expected SHA256")
	delete(got, context.allocator)

	// A second download is a cache hit and needs no network.
	path2, err2 := Download(d, url, sum)
	testing.expectf(t, err2 == .None, "cached re-download should succeed, got: {}", err2)
	testing.expect(t, path2 == path, "cache hit returns the same path")

	delete(path, context.allocator)
	delete(path2, context.allocator)
}
