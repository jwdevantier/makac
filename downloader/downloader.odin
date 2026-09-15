// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
///
/// downloader — URL-keyed file cache. Downloads a URL, optionally verifies a
/// SHA256 checksum, caches the file under `<cacheDir>/<sha256(url)>`, and
/// returns the on-disk path.
///
/// The package never implements HTTP or hashing itself:
///   - Downloads shell out to the `curl` CLI (see `curl_cli_download`). The
///     `vendor:curl` binding ships a libcurl built against mbedTLS and still
///     requires libmbedtls/libmbedcrypto/libmbedx509/libz as system libraries
///     at link- and run-time; the `curl` binary itself bundles those transitive
///     deps, so shelling out is the minimum-dependency way to make an HTTP
///     request — one program on PATH, like `git`/`tar`.
///   - Checksums/hash keys use the stdlib `core:crypto/hash` + hex packages.
///
/// Example:
///
///	path, err := downloader.Download(d, "https://example.com/a.tgz", "<sha256>")
///	if err != .None { /* handle */ }
///	// `path` is the on-disk cached file; it is caller-owned.
///	defer delete(path, context.allocator)
package downloader

import "base:runtime"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

import sp "../subprocess"

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Error codes returned by the package. `.None` means success.
Error :: enum {
	None, ///< Success.
	Bad_Arguments, ///< Called with arguments that cannot be used (e.g. empty URL).
	Mkdir_Failure, ///< Failed to create the cache directory.
	Write_Failure, ///< Failed to write the downloaded temp file.
	Checksum_Mismatch, ///< Downloaded bytes did not hash to the expected SHA256.
	Download_Failure, ///< The download itself failed (curl, network, HTTP status, ...).
}

/// error_string renders an Error code for user-facing messages.
error_string :: proc(err: Error) -> string {
	switch err {
	case .None:
		return "no error"
	case .Bad_Arguments:
		return "bad arguments (the URL is empty)"
	case .Mkdir_Failure:
		return "could not create the cache directory"
	case .Write_Failure:
		return "could not write the downloaded file"
	case .Checksum_Mismatch:
		return "checksum mismatch"
	case .Download_Failure:
		return "the download failed (network, HTTP status, or curl not found)"
	}
	return "unknown error"
}

// ---------------------------------------------------------------------------
// Core type
// ---------------------------------------------------------------------------

/// Downloader wraps a single cache directory shared across all fetched files.
///
/// Downloaded content is keyed by the SHA256 of its URL: the file fetched from
/// `url` is stored at `<cacheDir>/<sha256hex(url)>` (see `url_cache_key`).
///
/// A Downloader is safe to reuse across calls; it owns no network state of its
/// own. (Concurrent downloads are out of scope for now.)
Downloader :: struct {
	cacheDir:      string, ///< Cache directory shared across all fetched files.
	download_impl: download_fn, ///< Transfer seam; defaults to `curl_cli_download` and can be
	///< swapped for a stub in tests (see the `ssh` package's
	///< `SSH_BIN` convention) so cache/hash logic runs with no network.
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// new_downloader wraps `cacheDir` in a Downloader. The caller owns the returned
/// pointer and must free it with `free`.
///
/// Convenience procs create their own Downloader internally; callers that need
/// to share a single cache directory across many downloads create one with this
/// proc and reuse it.
new_downloader :: proc(cacheDir: string) -> ^Downloader {
	d := new(Downloader, context.allocator)
	d.cacheDir = cacheDir
	d.download_impl = curl_cli_download
	return d
}

// ---------------------------------------------------------------------------
// Cache-key core (network-free)
// ---------------------------------------------------------------------------

/// url_cache_key computes the cache key of `url`: the lowercase SHA256 hex
/// digest of the URL string itself. Two different URLs never share a slot, and
/// a URL fetched without a checksum still gets a stable, well-defined entry.
///
/// The returned string is caller-owned and must be freed with `delete`.
url_cache_key :: proc(url: string, allocator: runtime.Allocator = context.allocator) -> string {
	raw := hash.hash_string(.SHA256, url, context.temp_allocator)
	enc, herr := hex.encode(raw, allocator)
	if herr != nil {
		// Allocation failure only; e3b0c44... is sha256("") so there is always
		// *some* valid key, but do not silently return it for a non-empty URL.
		return ""
	}
	return string(enc)
}

/// GetCachedPath returns the path where the file fetched from `url` is cached,
/// namely `<cacheDir>/<sha256hex(url)>`.
///
/// The returned string is owned by the caller, free with `delete(path, allocator)`.
GetCachedPath :: proc(
	self: ^Downloader,
	url: string,
	allocator: runtime.Allocator = context.allocator,
) -> string {
	key := url_cache_key(url, context.temp_allocator)
	path, path_err := os.join_path([]string{self.cacheDir, key}, allocator)
	if path_err != nil {
		// Path building only fails on allocation failure; fall back to a plain
		// join so callers still get a usable (if un-normalised) path rather
		// than crashing.
		return strings.join([]string{self.cacheDir, key}, os.Path_Separator_String, allocator)
	}
	return path
}

/// IsCached reports whether an entry for `url` is already present in the cache.
///
/// This is a pure existence check: `Download` re-verifies cached content
/// against an expected checksum (when given) before returning it, so a caller
/// never receives a corrupt entry.
IsCached :: proc(self: ^Downloader, url: string) -> bool {
	if url == "" {
		return false
	}
	cached_path := GetCachedPath(self, url, context.temp_allocator)
	return os.exists(cached_path)
}

// ---------------------------------------------------------------------------
// Download
// ---------------------------------------------------------------------------

/// Download returns the path of the cached file fetched from `url`: on a cache
/// hit the existing entry is returned, otherwise the URL is fetched (through
/// the `download_impl` seam), written to a temp file, and atomically moved into
/// `<cacheDir>/<sha256hex(url)>`.
///
/// `expected_sha256` (optional, may be "") is checked against the downloaded
/// bytes. When a checksum is given and a cached entry fails verification, the
/// entry is dropped and the URL is re-downloaded; a mismatch after download is
/// a `.Checksum_Mismatch` error and nothing is cached.
///
/// The returned path is owned by the caller (it allocates via `core:os`) and
/// must be freed with `delete(path, allocator)`.
///
/// Steps:
///   1. If `url` is empty → `.Bad_Arguments` (no work).
///   2. If the entry exists AND ("no checksum" OR "verifies") → cache hit.
///      A present-but-mismatching entry is removed (it is corrupt/wrong).
///   3. `mkdir_all(cacheDir, 0755)`.
///   4. Download into bytes via the seam.
///   5. Write bytes to `<final>.tmp`; if a checksum was given and the temp
///      file fails it → remove the temp file, `.Checksum_Mismatch`.
///   6. `rename(tmp → final)` for atomic-ish placement.
///   7. The temp file is removed on every failure path.
///
/// The transfer itself is delegated to `self.download_impl` (the seam), so the
/// cache/hash/rename logic runs identically whether the transfer is a real
/// `curl_cli_download` or a test stub.
Download :: proc(
	self: ^Downloader,
	url: string,
	expected_sha256: string = "",
	allocator: runtime.Allocator = context.allocator,
) -> (
	path: string,
	err: Error,
) {
	if url == "" {
		return "", .Bad_Arguments
	}

	expected := strings.to_lower(expected_sha256, context.temp_allocator)
	final_path := GetCachedPath(self, url, context.temp_allocator)

	// Cache hit: reuse a cached entry only when no checksum was given or the
	// cached contents verify. A mismatching entry is corrupt/wrong — drop it
	// and fall through to a fresh download.
	if os.exists(final_path) {
		if expected == "" || file_matches_sha256(final_path, expected) {
			final_clone, cerr := strings.clone(final_path, allocator)
			if cerr != nil {
				return "", .Write_Failure
			}
			return final_clone, .None
		}
		os.remove(final_path)
	}

	// Ensure the cache directory exists (idempotent; `.Exist` is success).
	if merr := os.mkdir_all(self.cacheDir, os.perm_number(0o755)); merr != nil && merr != .Exist {
		return "", .Mkdir_Failure
	}

	// Stream the body straight into a temp file: the body never enters
	// parent memory, so a multi-GB download does not spike RSS. The seam
	// opens/truncates the file; on failure the partial file is removed.
	tmp_path := strings.concatenate([]string{final_path, ".tmp"}, context.temp_allocator)
	if dl_err := self.download_impl(url, tmp_path); dl_err != .None {
		os.remove(tmp_path)
		return "", .Download_Failure
	}

	// Verify the downloaded bytes against the expected SHA256, when given.
	if expected != "" && !file_matches_sha256(tmp_path, expected) {
		os.remove(tmp_path)
		return "", .Checksum_Mismatch
	}

	// Atomically-ish place the verified content at its final name.
	if os.rename(tmp_path, final_path) != nil {
		os.remove(tmp_path)
		return "", .Write_Failure
	}

	final_clone, cerr := strings.clone(final_path, allocator)
	if cerr != nil {
		return "", .Write_Failure
	}
	return final_clone, .None
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// hash_file computes the lowercase SHA256 hex digest of the file at
/// `filename` using the stdlib `core:crypto/hash` package.
///
/// It returns the allocated digest (which the caller must `delete`) and an
/// `io.Error` on failure. The returned `[]byte` slice is the hex string,
/// caller-owned.
hash_file :: proc(
	filename: string,
	allocator: runtime.Allocator = context.allocator,
) -> (
	digest: []byte,
	err: io.Error,
) {
	raw, rerr := hash.hash_file_by_name(
		hash.Algorithm.SHA256,
		filename,
		true,
		context.temp_allocator,
	)
	if rerr != nil {
		return nil, rerr
	}

	out, herr := hex.encode(raw, allocator)
	if herr != nil {
		return nil, io.Error.Unknown
	}

	return out, nil
}

/// file_matches_sha256 reports whether the file at `path` hashes to
/// `expected` (a lowercase SHA256 hex digest). An unreadable file never
/// matches.
file_matches_sha256 :: proc(path, expected: string) -> bool {
	digest, _ := hash_file(path, context.temp_allocator)
	if digest == nil {
		return false
	}
	return string(digest) == expected
}

// ---------------------------------------------------------------------------
// Download seam
// ---------------------------------------------------------------------------

/// download_fn is the signature of the transfer seam. Given a `url`, it
/// writes the response body into the file at `dest_path`, creating or
/// truncating the file as needed. On success the file contains the full
/// body; on failure the file's contents are unspecified (the caller is
/// responsible for removing it).
///
/// The default implementation is `curl_cli_download`. Tests replace it with a
/// stub (set on `Downloader.download_impl`) so the cache/hash/rename logic
/// can be exercised with no network — mirroring the `ssh` package repointing
/// `SSH_BIN`.
download_fn :: proc(url: string, dest_path: string) -> Error

/// curl_cli_download is the default `download_fn`: it shells out to the `curl`
/// CLI (`curl -fsSL --proto =http,https --proto-redir =http,https -o <dest> -- url`)
/// which streams the response body straight to `dest_path` — the body never
/// touches the parent's address space, so multi-GB transfers do not spike
/// RSS. See the package doc for why we use the CLI rather than `vendor:curl`.
///
/// Flags: `-f` fail with non-zero exit on HTTP errors, `-sL` silent and
/// follow redirects, `--proto[`-redir`]` clamped to http(s) — plus `file` on
/// `--proto` so local tarballs can be served without a network (offline
/// tests, pre-seeded mirrors) — `-o <dest_path>` write body to that file,
/// `--` end of options (so a URL can never be read as a flag).
curl_cli_download :: proc(url: string, dest_path: string) -> Error {
	args := []string {
		"curl",
		"-fsSL",
		"--proto",
		"=http,https,file",
		"--proto-redir",
		"=http,https",
		"-o",
		dest_path,
		"--",
		url,
	}
	// stdout is unused: `curl -o <dest_path>` writes the body to the file,
	// not to stdout. run_capture still allocates an empty stdout buffer; that
	// is reclaimed on the temp arena's next free_all.
	_, stderr, code, run_err := run_capture(args, context.temp_allocator, context.temp_allocator)
	defer delete(stderr, context.temp_allocator)
	if run_err != nil {
		msg := os.error_string(run_err)
		fmt.eprintf("makac: download of '%s' failed: cannot run curl: %s\n", url, msg)
		return .Download_Failure
	}
	if code != 0 {
		fmt.eprintf(
			"makac: download of '%s' failed: curl exited %d: %s\n",
			url,
			code,
			string(stderr),
		)
		return .Download_Failure
	}
	return .None
}

/// run_capture spawns `argv` (argv[0] resolved via the parent PATH) and drains
/// its stdout/stderr concurrently until exit. Both streams are buffered in
/// memory: `stdout_alloc`/`stderr_alloc` own the returned buffers, which the
/// caller must `delete`.
///
/// A non-zero exit code is data, not an error; only failing to spawn the
/// program is an error. (Mirrors `vm.exec_capture`; now a thin wrapper
/// around `subprocess.Run` — the downloader package must not depend on
/// `vm` since `vm` depends on it.)
run_capture :: proc(
	argv: []string,
	stdout_alloc, stderr_alloc: runtime.Allocator,
) -> (
	stdout, stderr: []byte,
	code: int,
	err: os.Error,
) {
	// Curl is invoked with `-o <dest_path>`: the body lands in a file, so
	// stdout has nothing meaningful. We still drain it (subprocess.Run
	// creates the pipe and discards bytes) so curl doesn't block on a
	// full pipe buffer; stderr is the only stream we actually keep.
	sub_res, sub_err := sp.Run(argv, sp.Options{
		capture_stdout = false,
		capture_stderr = true,
		allocator      = stderr_alloc,
	})
	if sub_err != nil {
		err = sub_err
		return
	}
	stdout = nil
	stderr = sub_res.stderr
	code = sub_res.code
	return
}

// ---------------------------------------------------------------------------
// Convenience layer
// ---------------------------------------------------------------------------

/// download is the convenience wrapper around `Downloader.Download`: it creates
/// a default `Downloader` (see `default_cache_dir`) and fetches `url`,
/// optionally verifying it against `sha256sum`, returning the on-disk path of
/// the cached file.
///
/// The returned path is owned by the caller (it allocates via `core:os`) and
/// must be freed with `delete(path, allocator)`.
download :: proc(
	url: string,
	sha256sum: string = "",
	allocator: runtime.Allocator = context.allocator,
) -> (
	path: string,
	err: Error,
) {
	d := new_downloader(default_cache_dir(context.temp_allocator))
	defer free(d)

	return Download(d, url, sha256sum, allocator)
}

/// default_cache_dir returns the downloader's cache directory: the
/// `MAKAC_CACHE_DIR` environment variable if set (and non-empty), otherwise
/// `$HOME/.cache/makac`.
///
/// The returned string is owned by the caller and must be freed with
/// `delete(path, allocator)`.
default_cache_dir :: proc(allocator: runtime.Allocator) -> string {
	if dir, ok := os.lookup_env_alloc("MAKAC_CACHE_DIR", allocator); ok && dir != "" {
		return dir
	}

	home, _ := os.lookup_env_alloc("HOME", allocator)
	path, _ := os.join_path([]string{home, ".cache", "makac"}, allocator)
	return path
}
