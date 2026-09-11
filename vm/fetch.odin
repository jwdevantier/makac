// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:strings"

import dl "../downloader"
import lua "vendor:lua/5.4"

// Registry key under which the VM's data directory is stored at creation, so
// C primitives handed a bare ^lua.State can recover it. See vm.new.
DATA_DIR_REGKEY :: "makac.data_dir"

// _data_dir returns the VM's data directory as recorded in the Lua registry
// (no copy — the string is owned by the state/VM), or "" when the VM was
// created data-dir-less.
_data_dir :: proc(L: ^lua.State) -> string {
	if lua.Type(lua.getfield(L, lua.REGISTRYINDEX, DATA_DIR_REGKEY)) == .STRING {
		s := lua.tostring(L, -1)
		lua.pop(L, 1)
		return runtime.cstring_to_string(s)
	}
	lua.pop(L, 1)
	return ""
}

// _download_impl backs both makac.fetch(url[, sha256]) and
// makac.download(url[, sha256[, cache_dir_hint]]).
//
// Fetches `url` over HTTP(S) into a cache directory keyed as
// `<cache_dir>/<sha256(url)>` (see the downloader package), optionally
// verifying the bytes against `sha256`, and returns the on-disk cached path.
// The fetch uses the on-disk cache: a second fetch of the same URL is served
// without a transfer (and is re-verified when a checksum is given — a corrupt
// entry is dropped and re-fetched). Failures (network, HTTP error, checksum
// mismatch, ...) raise a Lua error naming the downloader error (e.g.
// "checksum mismatch").
//
// The cache directory is `<data_dir>/cache` by default; makac.download's
// optional third argument overrides it (a cache-dir hint — e.g. the fetch
// driver passing its own cache). A data-dir-less VM may only download with an
// explicit hint.
_download_impl :: proc "c" (L: ^lua.State, name: cstring) -> c.int {
	context = runtime.default_context()

	url := runtime.cstring_to_string(lua.L_checkstring(L, 1))
	sha := ""
	if !lua.isnoneornil(L, 2) {
		lua.L_checktype(L, 2, c.int(lua.Type.STRING))
		sha = runtime.cstring_to_string(lua.tostring(L, 2))
	}

	cache_dir := ""
	if !lua.isnoneornil(L, 3) {
		// explicit cache-directory hint (a non-empty string)
		lua.L_checktype(L, 3, c.int(lua.Type.STRING))
		cache_dir = runtime.cstring_to_string(lua.tostring(L, 3))
		if cache_dir != "" {
			// clone into the temp allocator; the lua string may be collected
			cache_dir = strings.clone(cache_dir, context.temp_allocator)
		}
	}
	if cache_dir == "" {
		data_dir := _data_dir(L)
		if data_dir == "" {
			return c.int(
				lua.L_error(
					L,
					"%s: cannot download: no data directory (internal: VM created data-dir-less)",
					name,
				),
			)
		}
		cache_dir = strings.concatenate([]string{data_dir, "/cache"}, context.temp_allocator)
	}

	d := dl.new_downloader(cache_dir)
	defer free(d)

	path, err := dl.Download(d, url, sha, context.temp_allocator)
	if err != .None {
		what := strings.clone_to_cstring(dl.error_string(err), context.temp_allocator)
		uc := strings.clone_to_cstring(url, context.temp_allocator)
		return c.int(lua.L_error(L, "%s: %s (url: %s)", name, what, uc))
	}

	lua.pushlstring(L, cstring(raw_data(path)), c.size_t(len(path)))
	return 1
}

_makac_fetch :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return _download_impl(L, "makac.fetch")
}

_makac_download :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return _download_impl(L, "makac.download")
}
