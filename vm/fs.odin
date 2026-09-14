// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

import lua "vendor:lua/5.4"

// makac.fs (design/stdlib.md) — the home of ALL flat filesystem
// primitives. This file holds the shared submodule plumbing and the
// directory-level entries; later tasks add paths, Dir handles, regular
// files/temp entries and hashing as fields of the same single `makac.fs`
// table (registered once, here).
//
//   makac.fs.mkdir_p(path)                    -- parents as needed;
//                                                 existing dir is FINE
//   makac.fs.listdir(path) -> { { name =, is_dir = }, ... } | nil, err
//   makac.fs.read_file(path) -> string | nil, err
//   makac.fs.write_file(path, data, { atomic = }?)
//   makac.fs.stat(path) -> { type =, size =, mtime_ns = } | nil
//   makac.fs.mktemp_dir(prefix?) -> path      -- created, mode 0700
//   makac.fs.mktemp_file(prefix?) -> path     -- created empty
//   makac.fs.sha256(path) -> hex_string | nil, err
//
// `listdir` is the moved flat `makac.listdir` (previously vm/listdir.odin):
// same entry shape, same nil, err absence convention; the flat name stays
// registered as an alias (the prelude enumerates packages through it).
//
// Path-ness: `check_path_string` (vm/path.odin) accepts a string or a
// `makac.path` userdata in every path-taking function here; string-or-path
// per stdlib.md. The mktemp_* and null_file returns are path values,
// produced by vm/path.odin's _push_path.
//
// NB `path` in every signature: a string-or-path once task 08 lands the
// path userdata (std convention: every path-taking fs function accepts
// either; string-only until then).

register_fs_primitives :: proc(v: ^VM) {
	L := v.state
	_push_submodule(v, "fs")
	register_path_on_fs(L)  // metatable + path/path_join/null_file/sep
	register_dir_on_fs(L)   // "makac.fs.Dir" metatable + cwd/open_dir
	defer lua.pop(L, 1)
	lua.pushcclosure(L, _makac_fs_mkdir_p, 0)
	lua.setfield(L, -2, "mkdir_p")
	lua.pushcclosure(L, _makac_listdir, 0)
	lua.setfield(L, -2, "listdir")
	lua.pushcclosure(L, _makac_fs_read_file, 0)
	lua.setfield(L, -2, "read_file")
	lua.pushcclosure(L, _makac_fs_write_file, 0)
	lua.setfield(L, -2, "write_file")
	lua.pushcclosure(L, _makac_fs_stat, 0)
	lua.setfield(L, -2, "stat")
	lua.pushcclosure(L, _makac_fs_mktemp_dir, 0)
	lua.setfield(L, -2, "mktemp_dir")
	lua.pushcclosure(L, _makac_fs_mktemp_file, 0)
	lua.setfield(L, -2, "mktemp_file")
	lua.pushcclosure(L, _makac_fs_sha256, 0)
	lua.setfield(L, -2, "sha256")
	// flat alias — the prelude's package enumeration predates submodules
	register(v, "listdir", _makac_listdir)
}

// makac.fs.listdir(path) -> array of {name = <string>, is_dir = <bool>} or
// (nil, err) when the directory cannot be read. Lua has no directory
// listing, and the prelude needs one to enumerate fetched packages under
// <datadir>/packages (see makac.load_packages and the pkgs: searcher).
//
// Returns (nil, err) instead of raising so Lua code can treat a missing
// packages dir as "no packages fetched yet" rather than an error.
//
// (Moved here from the flat `makac.listdir` of stage 1 — same entry shape,
// same absence convention; also registered flat as `makac.listdir`.)
_makac_listdir :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	path := check_path_string(L, 1)
	fis, err := os.read_directory_by_path(path, -1, context.temp_allocator)
	if err != nil {
		lua.pushnil(L)
		errmsg := fmt.tprintf("cannot list directory '%s': %v", path, err)
		lua.pushfstring(L, "%s", cstring(raw_data(errmsg)))
		return 2
	}
	lua.createtable(L, c.int(len(fis)), 0)
	for fi, i in fis {
		lua.createtable(L, 0, 2)
		lua.pushlstring(L, cstring(raw_data(fi.name)), c.size_t(len(fi.name)))
		lua.setfield(L, -2, "name")
		lua.pushboolean(L, b32(fi.type == .Directory))
		lua.setfield(L, -2, "is_dir")
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

// makac.fs.mkdir_p(path) — create `path` and any missing parents. Existing
// dir (whole or part) is fine; raises when a component is a regular file or
// creation fails. core:os's make_directory_all reports .Exist when the LEAF
// already exists (intermediate components are tolerated by it) — treat an
// existing directory as success, anything else (e.g. a file) as the raise.
@(private = "file")
_makac_fs_mkdir_p :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	path := check_path_string(L, 1)
	err := os.make_directory_all(path)
	if err != nil {
		if err == .Exist && os.is_dir(path) {
			return 0
		}
		errmsg := fmt.tprintf("cannot create directory '%s': %v", path, err)
		return c.int(lua.L_error(L, "makac.fs: mkdir_p: %s", cstring(raw_data(errmsg))))
	}
	return 0
}

// makac.fs.read_file(path) -> string | nil, err — one-call slurp. Returns
// (nil, err) instead of raising (the listdir precedent): "input file gone"
// is data to the callers (stages rebuild), not an exception.
@(private = "file")
_makac_fs_read_file :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	path := check_path_string(L, 1)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		lua.pushnil(L)
		errmsg := fmt.tprintf("cannot read file '%s': %v", path, err)
		lua.pushfstring(L, "%s", cstring(raw_data(errmsg)))
		return 2
	}
	lua.pushlstring(L, cstring(raw_data(data)), c.size_t(len(data)))
	return 1
}

// makac.fs.write_file(path, data, { atomic = }?) — write `data` to `path`.
// With atomic = true the data goes to a sibling temp file first and is then
// renamed over the target: a concurrent `makac run` attaching to a named VM
// must never observe a half-written `invocation` or manifest (handle.md's
// re-derivation across runs is precisely concurrent readers of these
// files). Without it, a plain truncating write. Raises on failure (writes
// are statements, not queries).
@(private = "file")
_makac_fs_write_file :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	path := check_path_string(L, 1)
	n: c.size_t
	datap := lua.L_checkstring(L, 2, &n)
	data := string(datap)[:n]
	atomic := false
	if !lua.isnoneornil(L, 3) {
		// getfield on an absent/nil slot indexes nil and raises — only touch
		// the opts table when one was actually passed.
		lua.L_checktype(L, 3, c.int(lua.Type.TABLE))
		lua.getfield(L, 3, "atomic")
		if lua.toboolean(L, -1) {atomic = true}
		lua.pop(L, 1)
	}
	if !atomic {
		err := os.write_entire_file_from_string(path, data)
		if err != nil {
			errmsg := fmt.tprintf("cannot write file '%s': %v", path, err)
			return c.int(lua.L_error(L, "makac.fs: write_file: %s", cstring(raw_data(errmsg))))
		}
		return 0
	}

	// Atomic: sibling temp file in the same directory (same filesystem —
	// rename(2) does not cross filesystems), mode 0600 (the core temp-file
	// helper's mode; invocation/manifest content is not world-readable), then
	// rename over the target. Any failure removes the temp file.
	dir, file := os.split_path(path)
	if file == "" {
		errmsg := fmt.tprintf("cannot write file '%s': not a file path", path)
		return c.int(lua.L_error(L, "makac.fs: write_file: %s", cstring(raw_data(errmsg))))
	}
	pattern := fmt.tprintf(".%s.makac-tmp-*", file)
	tmp, oerr := os.create_temp_file(dir, pattern)
	if oerr != nil {
		errmsg := fmt.tprintf("cannot create temp file for atomic write of '%s': %v", path, oerr)
		return c.int(lua.L_error(L, "makac.fs: write_file: %s", cstring(raw_data(errmsg))))
	}
	tmpname := strings.clone(os.name(tmp), context.temp_allocator)
	fail := proc(msg: string, args: ..any) -> string {
		return fmt.tprintf(msg, ..args)
	}
	_, werr := os.write_string(tmp, data)
	if werr == nil {
		werr = os.close(tmp)
	} else {
		os.close(tmp)
	}
	if werr != nil {
		os.remove(tmpname)
		errmsg := fail("cannot write file '%s': %v", path, werr)
		return c.int(lua.L_error(L, "makac.fs: write_file: %s", cstring(raw_data(errmsg))))
	}
	if rerr := os.rename(tmpname, path); rerr != nil {
		os.remove(tmpname)
		errmsg := fail("cannot rename temp file over '%s': %v", path, rerr)
		return c.int(lua.L_error(L, "makac.fs: write_file: %s", cstring(raw_data(errmsg))))
	}
	return 0
}

// makac.fs.stat(path) -> { type =, size =, mtime_ns = } | nil — existence
// plus kind, in one lstat(2) (NOT stat: a `link` answer for a dangling
// symlink is worth more than nil). `type` is one of
// "file" | "dir" | "socket" | "link" | "other"; nil when the path does not
// exist (absence is an answer — io.open(p) == nil can't tell a missing pid
// file from a present socket, and handle.md's probe needs the distinction).
@(private = "file")
_makac_fs_stat :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	path := check_path_string(L, 1)
	fi, err := os.lstat(path, context.temp_allocator)
	if err != nil {
		if err == .Not_Exist {
			lua.pushnil(L)
			return 1
		}
		errmsg := fmt.tprintf("cannot stat '%s': %v", path, err)
		return c.int(lua.L_error(L, "makac.fs: stat: %s", cstring(raw_data(errmsg))))
	}
	kind := _file_type_name(fi.type)
	lua.createtable(L, 0, 3)
	lua.pushstring(L, cstring(raw_data(kind)))
	lua.setfield(L, -2, "type")
	lua.pushinteger(L, lua.Integer(fi.size))
	lua.setfield(L, -2, "size")
	mtime_ns := time.time_to_unix_nano(fi.modification_time)
	lua.pushinteger(L, lua.Integer(mtime_ns))
	lua.setfield(L, -2, "mtime_ns")
	return 1
}

// makac.fs.mktemp_dir(prefix?) -> path — create a fresh directory, mode
// 0700, rooted in the system temp dir; the CALLER removes it. Raises on
// failure. `prefix` is incorporated into the name so temp entries are
// recognizable. (Lua's os.tmpname hands out a bare name without creating
// anything — race-prone and file-only.) core:os's make_directory_temp uses
// the default 0755; these are private scratch dirs, so tighten to 0700.
@(private = "file")
_makac_fs_mktemp_dir :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	pattern := _mktemp_pattern(L)
	dir, err := os.make_directory_temp("", pattern, context.temp_allocator)
	if err != nil {
		errmsg := fmt.tprintf("cannot create temp directory: %v", err)
		return c.int(lua.L_error(L, "makac.fs: mktemp_dir: %s", cstring(raw_data(errmsg))))
	}
	if cerr := os.change_mode(dir, os.perm_number(0o700)); cerr != nil {
		os.remove_all(dir)
		errmsg := fmt.tprintf("cannot chmod temp directory '%s': %v", dir, cerr)
		return c.int(lua.L_error(L, "makac.fs: mktemp_dir: %s", cstring(raw_data(errmsg))))
	}
	_push_path(L, dir)
	return 1
}

// makac.fs.mktemp_file(prefix?) -> path — create a fresh EMPTY file in the
// system temp dir (the core helper's O_EXCL create loop), close it, and
// return its path for the caller to fill (io.open for writing) and remove.
// Raises on failure.
@(private = "file")
_makac_fs_mktemp_file :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	pattern := _mktemp_pattern(L)
	f, err := os.create_temp_file("", pattern)
	if err != nil {
		errmsg := fmt.tprintf("cannot create temp file: %v", err)
		return c.int(lua.L_error(L, "makac.fs: mktemp_file: %s", cstring(raw_data(errmsg))))
	}
	// Clone BEFORE close: os.name re-reads /proc/self/fd/<n>, which is gone
	// once the fd is closed (core:os bug — name() after close hangs).
	name := strings.clone(os.name(f), context.temp_allocator)
	os.close(f)
	_push_path(L, name)
	return 1
}

// makac.fs.sha256(path) -> hex_string | nil, err — STREAMS the file
// (core:crypto/hash's hash_file_by_name with load_at_once = false feeds the
// hasher through hash_stream in chunks; image inputs can be gigabytes, and
// there is deliberately no string-taking variant to encourage loading one
// into Lua). Hex-encoded result. (nil, err) for a missing/unreadable file:
// to an images.md manifest, "input file gone" is data (the stage rebuilds),
// not an exception. Same hashing approach as the downloader's hash_file /
// file_matches_sha256 (downloader/downloader.odin).
@(private = "file")
_makac_fs_sha256 :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	path := check_path_string(L, 1)
	raw, rerr := hash.hash_file_by_name(.SHA256, path, false, context.temp_allocator)
	if rerr != nil {
		lua.pushnil(L)
		errmsg := fmt.tprintf("cannot hash file '%s': %v", path, rerr)
		lua.pushfstring(L, "%s", cstring(raw_data(errmsg)))
		return 2
	}
	hexd, herr := hex.encode(raw, context.temp_allocator)
	if herr != nil {
		lua.pushnil(L)
		errmsg := fmt.tprintf("cannot hash file '%s': hex encode failed", path)
		lua.pushfstring(L, "%s", cstring(raw_data(errmsg)))
		return 2
	}
	lua.pushlstring(L, cstring(raw_data(hexd)), c.size_t(len(hexd)))
	return 1
}

// The temp-entry name pattern for core:os's create_temp_file /
// make_directory_temp: the caller's `prefix` (arg 1, optional string;
// anything else raises via L_checkstring) incorporated so temp entries are
// recognizable, followed by the "*" the random component replaces.
@(private = "file")
_mktemp_pattern :: proc(L: ^lua.State) -> string {
	if !lua.isnoneornil(L, 1) {
		prefix := runtime.cstring_to_string(lua.L_checkstring(L, 1))
		return fmt.tprintf("%s*", prefix)
	}
	return "makac-*"
}
