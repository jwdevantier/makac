// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import lua "vendor:lua/5.4"

// makac.fs — directory handles (`Dir`) (design2/stdlib.md, "makac.fs —
// directory handles (Dir)"). A Dir is a userdata with metatable
// "makac.fs.Dir" holding ONE canonical absolute path (resolved at
// construction) — no fd, nothing to close; the threat model is a local
// workflow tool, so the anchor is a PATH plus a subpath guard, not an fd.
// Every operation takes an optional `sub` relative to the root, validated:
// must be relative, no '..' component (violations raise).
//
//   makac.fs.cwd() -> Dir
//   makac.fs.open_dir(path|path_str) -> Dir   -- raises unless exists & is dir
//
//   d:path() -> path
//   d:exists(sub?) -> bool             -- plain boolean; absence is an answer
//   d:touch(sub)                       -- create empty file; raises
//   d:make_path(sub)                   -- mkdir -p relative to root; raises
//   d:open_dir(sub) -> Dir             -- descend
//   d:parent() -> Dir                  -- pure navigation (no existence check)
//   d:list() -> { { name =, type = }, ... }   -- one level; stat vocabulary
//   d:walk() -> iterator               -- depth-first, generic-for
//   d:remove(sub?)                     -- recursive for dirs; sub-omitted
//                                         -- removes the root itself
//
// `exists`/`touch`/`remove` with sub omitted operate on the root itself;
// after d:remove() the handle is stale and reports accordingly (exists()
// -> false). Path-anchored with a subpath guard — NOT fd-anchored; the
// spec documents that simplification explicitly.

DIR_MT  :: "makac.fs.Dir"
WALK_MT :: "makac.fs.walk"

Dir_Value :: struct {
	root: string, // owned (context.allocator); canonical absolute path
}

// Walk entry/state. `sub` is owned (context.allocator); `kind` points to a
// static literal of the stat vocabulary, so __gc only frees sub + slice.
// The iterator is an EAGER snapshot: d:walk() collects the whole tree
// depth-first up front, so mutating the tree while iterating (e.g. pruning
// entries mid-walk — exactly what cleanup code does) is safe, and there is
// no half-open directory stack to leak on a Lua-side break/error.
Walk_Entry :: struct {
	sub:  string,
	kind: string,
}

Walk_State :: struct {
	entries: []Walk_Entry, // owned (context.allocator)
	idx:     int,
}

// register_dir_on_fs — called by fs.odin's register_fs_primitives while the
// `makac.fs` submodule table sits at top of stack (same disposition as
// register_path_on_fs). Creates the DIR and WALK metatables and sets
// cwd/open_dir on the fs table.
register_dir_on_fs :: proc "c" (L: ^lua.State) {
	context = runtime.default_context()
	if lua.L_newmetatable(L, DIR_MT) != 0 {
		lua.pushcclosure(L, _dir_index, 0)
		lua.setfield(L, -2, "__index")
		lua.pushcclosure(L, _dir_gc, 0)
		lua.setfield(L, -2, "__gc")
		lua.pushcclosure(L, _dir_tostring, 0)
		lua.setfield(L, -2, "__tostring")
	}
	lua.pop(L, 1)
	if lua.L_newmetatable(L, WALK_MT) != 0 {
		lua.pushcclosure(L, _walk_state_gc, 0)
		lua.setfield(L, -2, "__gc")
	}
	lua.pop(L, 1)

	lua.pushcclosure(L, _makac_fs_cwd, 0)
	lua.setfield(L, -2, "cwd")
	lua.pushcclosure(L, _makac_fs_open_dir, 0)
	lua.setfield(L, -2, "open_dir")
}

// _push_dir — wrap `abs` (must already be absolute+cleaned) in a Dir
// userdata on top of the stack, cloning so __gc owns it.
_push_dir :: proc "c" (L: ^lua.State, abs: string) {
	context = runtime.default_context()
	ud := (^Dir_Value)(lua.newuserdata(L, c.size_t(size_of(Dir_Value))))
	ud^ = Dir_Value{root = strings.clone(abs, context.allocator)}
	lua.L_setmetatable(L, DIR_MT)
}

// _file_type_name — the fs.stat type vocabulary, shared between stat
// (lstat) and Dir list/walk (read_directory entries, opened NOFOLLOW so
// symlinks report as links, matching lstat semantics).
_file_type_name :: proc(ft: os.File_Type) -> string {
	#partial switch ft {
	case .Regular:   return "file"
	case .Directory: return "dir"
	case .Socket:    return "socket"
	case .Symlink:   return "link"
	}
	return "other"
}

// dir_check_sub — validate a `sub` argument: must be relative (no leading
// '/') and contain no '..' component; violations RAISE. Accepts string-or-
// path like every fs path argument (check_path_string). Returns the raw
// sub string (stack-anchored or userdata-owned).
dir_check_sub :: proc "c" (L: ^lua.State, idx: c.int) -> string {
	context = runtime.default_context()
	s := check_path_string(L, idx)
	if filepath.is_abs(s) {
		msg := fmt.tprintf("sub '%s' must be relative", s)
		lua.L_error(L, "makac.fs: Dir: %s", cstring(raw_data(msg)))
		return ""
	}
	for comp in strings.split(s, "/", context.temp_allocator) {
		if comp == ".." {
			msg := fmt.tprintf("sub '%s' must not contain '..'", s)
			lua.L_error(L, "makac.fs: Dir: %s", cstring(raw_data(msg)))
			return ""
		}
	}
	return s
}

// dir_join — root + validated sub, or the root itself when sub is empty.
// Scratch in temp_allocator; one call per operation.
dir_join :: proc(root, sub: string) -> string {
	if sub == "" {return root}
	joined, err := filepath.join([]string{root, sub}, context.temp_allocator)
	if err != nil {return root} // allocator failure only; unreachable in practice
	return joined
}

// dir_target — resolve the target of an operation whose sub argument (at
// `idx`) is OPTIONAL: omitted/nil/explicit "" means the root itself.
dir_target_optional :: proc "c" (L: ^lua.State, self: ^Dir_Value, idx: c.int) -> string {
	context = runtime.default_context()
	sub := ""
	if !lua.isnoneornil(L, idx) {
		sub = dir_check_sub(L, idx)
	}
	return dir_join(self.root, sub)
}

// dir_target_required — resolve the target of an operation whose sub is
// REQUIRED (touch/make_path/open_dir); a missing/nil argument raises.
dir_target_required :: proc "c" (L: ^lua.State, self: ^Dir_Value, idx: c.int) -> string {
	context = runtime.default_context()
	if lua.isnoneornil(L, idx) {
		lua.L_error(L, "makac.fs: Dir: sub argument required (#%d)", idx)
		return ""
	}
	return dir_join(self.root, dir_check_sub(L, idx))
}

// __index: method dispatch.
@(private = "file")
_dir_index :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	if lua.Type(lua.type(L, 2)) != .STRING {
		lua.pushnil(L)
		return 1
	}
	switch runtime.cstring_to_string(lua.tostring(L, 2)) {
	case "path":      lua.pushcclosure(L, _dir_path, 0)
	case "exists":    lua.pushcclosure(L, _dir_exists, 0)
	case "touch":     lua.pushcclosure(L, _dir_touch, 0)
	case "make_path": lua.pushcclosure(L, _dir_make_path, 0)
	case "open_dir":  lua.pushcclosure(L, _dir_open_dir, 0)
	case "parent":    lua.pushcclosure(L, _dir_parent, 0)
	case "list":      lua.pushcclosure(L, _dir_list, 0)
	case "walk":      lua.pushcclosure(L, _dir_walk, 0)
	case "remove":    lua.pushcclosure(L, _dir_remove, 0)
	case:             lua.pushnil(L)
	}
	return 1
}

@(private = "file")
_dir_gc :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Dir_Value)(lua.L_checkudata(L, 1, DIR_MT))
	if self.root != "" {delete(self.root, context.allocator)}
	self^ = {}
	return 0
}

@(private = "file")
_dir_tostring :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Dir_Value)(lua.L_checkudata(L, 1, DIR_MT))
	lua.pushlstring(L, cstring(raw_data(self.root)), c.size_t(len(self.root)))
	return 1
}

// ---------------- constructors ----------------

// makac.fs.cwd() -> Dir — the directory makac was invoked in. getcwd(2)
// already returns an absolute, cleaned path.
@(private = "file")
_makac_fs_cwd :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil {
		msg := fmt.tprintf("cannot determine working directory: %v", err)
		return c.int(lua.L_error(L, "makac.fs: cwd: %s", cstring(raw_data(msg))))
	}
	_push_dir(L, cwd)
	return 1
}

// makac.fs.open_dir(p) -> Dir — raises unless `p` exists and is a dir.
// The root is canonicalized to absolute+cleaned (filepath.abs joins with
// the process cwd when relative); symlinks are NOT resolved — the anchor
// is the path as named, per the documented simplification.
@(private = "file")
_makac_fs_open_dir :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	s := check_path_string(L, 1)
	abs, aerr := filepath.abs(s, context.temp_allocator)
	if aerr != nil {
		msg := fmt.tprintf("cannot resolve '%s': %v", s, aerr)
		return c.int(lua.L_error(L, "makac.fs: open_dir: %s", cstring(raw_data(msg))))
	}
	if !os.is_directory(abs) {
		msg := fmt.tprintf("'%s' does not exist or is not a directory", abs)
		return c.int(lua.L_error(L, "makac.fs: open_dir: %s", cstring(raw_data(msg))))
	}
	_push_dir(L, abs)
	return 1
}

// ---------------- methods ----------------

// d:path() -> path — the canonical absolute root.
@(private = "file")
_dir_path :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Dir_Value)(lua.L_checkudata(L, 1, DIR_MT))
	_push_path(L, self.root)
	return 1
}

// d:exists(sub?) -> bool — plain boolean: absence is an answer, never a
// raise. Omit sub to query the root itself (a stale handle reports false).
@(private = "file")
_dir_exists :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Dir_Value)(lua.L_checkudata(L, 1, DIR_MT))
	full := dir_target_optional(L, self, 2)
	lua.pushboolean(L, b32(os.exists(full)))
	return 1
}

// d:touch(sub) — create an empty file (no truncation of an existing one,
// no parent creation; the make_path sibling is the mkdir -p one). Raises.
@(private = "file")
_dir_touch :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Dir_Value)(lua.L_checkudata(L, 1, DIR_MT))
	full := dir_target_required(L, self, 2)
	f, ferr := os.open(full, os.File_Flags{.Create, .Write}, os.perm_number(0o644))
	if ferr != nil {
		msg := fmt.tprintf("cannot touch '%s': %v", full, ferr)
		return c.int(lua.L_error(L, "makac.fs: Dir: touch: %s", cstring(raw_data(msg))))
	}
	if cerr := os.close(f); cerr != nil {
		msg := fmt.tprintf("cannot close touched file '%s': %v", full, cerr)
		return c.int(lua.L_error(L, "makac.fs: Dir: touch: %s", cstring(raw_data(msg))))
	}
	return 0
}

// d:make_path(sub) — mkdir -p relative to the root. Existing dir (whole or
// part) is fine (same tolerance as fs.mkdir_p); raises otherwise.
@(private = "file")
_dir_make_path :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Dir_Value)(lua.L_checkudata(L, 1, DIR_MT))
	full := dir_target_required(L, self, 2)
	err := os.make_directory_all(full)
	if err != nil {
		if err == .Exist && os.is_dir(full) {
			return 0
		}
		msg := fmt.tprintf("cannot create directory '%s': %v", full, err)
		return c.int(lua.L_error(L, "makac.fs: Dir: make_path: %s", cstring(raw_data(msg))))
	}
	return 0
}

// d:open_dir(sub) -> Dir — descend into a subdirectory handle; raises
// unless the joined path exists and is a dir. The joined path is already
// absolute (root absolute + relative sub + clean via filepath.join).
@(private = "file")
_dir_open_dir :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Dir_Value)(lua.L_checkudata(L, 1, DIR_MT))
	full := dir_target_required(L, self, 2)
	if !os.is_directory(full) {
		msg := fmt.tprintf("'%s' does not exist or is not a directory", full)
		return c.int(lua.L_error(L, "makac.fs: Dir: open_dir: %s", cstring(raw_data(msg))))
	}
	_push_dir(L, full)
	return 1
}

// d:parent() -> Dir — the root's parent. Pure path navigation (like
// path:dirname()); NO existence check — open_dir/makac.fs.open_dir are the
// validating constructors. The parent of "/" is "/".
@(private = "file")
_dir_parent :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Dir_Value)(lua.L_checkudata(L, 1, DIR_MT))
	_push_dir(L, filepath.dir(self.root))
	return 1
}

// d:list() -> { { name =, type = }, ... } — one level; `type` is the
// fs.stat vocabulary. Raises when the directory cannot be read (a stale
// handle raising here is fine: exists() is the query that reports absence
// as a plain answer).
@(private = "file")
_dir_list :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Dir_Value)(lua.L_checkudata(L, 1, DIR_MT))
	fis, err := os.read_directory_by_path(self.root, -1, context.temp_allocator)
	if err != nil {
		msg := fmt.tprintf("cannot list directory '%s': %v", self.root, err)
		return c.int(lua.L_error(L, "makac.fs: Dir: list: %s", cstring(raw_data(msg))))
	}
	lua.createtable(L, c.int(len(fis)), 0)
	for fi, i in fis {
		lua.createtable(L, 0, 2)
		lua.pushlstring(L, cstring(raw_data(fi.name)), c.size_t(len(fi.name)))
		lua.setfield(L, -2, "name")
		kind := _file_type_name(fi.type)
		lua.pushlstring(L, cstring(raw_data(kind)), c.size_t(len(kind)))
		lua.setfield(L, -2, "type")
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

// d:remove(sub?) — recursive for directories; sub omitted removes the root
// itself. Removing an absent target raises (remove is a statement — an
// absent target is almost certainly a workflow logic error). After
// d:remove() the handle is stale: operations keep working on the now-absent
// path and report accordingly (exists() -> false).
@(private = "file")
_dir_remove :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Dir_Value)(lua.L_checkudata(L, 1, DIR_MT))
	full := dir_target_optional(L, self, 2)
	rerr := os.remove_all(full)
	if rerr != nil {
		msg := fmt.tprintf("cannot remove '%s': %v", full, rerr)
		return c.int(lua.L_error(L, "makac.fs: Dir: remove: %s", cstring(raw_data(msg))))
	}
	return 0
}

// ---------------- walk ----------------

// _walk_collect — depth-first: append (sub, kind) for every entry under
// root/rel, recursing into directories (symlinks are NOT followed, so no
// loops). Entries of a directory are appended AFTER the directory itself
// was appended by the caller — directories are yielded before their
// contents. Failures return the os.Error; collected subs are freed by the
// caller before raising.
_walk_collect :: proc(root, rel: string, out: ^[dynamic]Walk_Entry) -> os.Error {
	full := rel == "" ? root : filepath.join([]string{root, rel}, context.temp_allocator) or_return
	fis, rerr := os.read_directory_by_path(full, -1, context.temp_allocator)
	if rerr != nil {return rerr}
	for fi in fis {
		sub := rel == "" ? fi.name : strings.concatenate({rel, "/", fi.name}, context.temp_allocator)
		owned := strings.clone(sub, context.allocator)
		append(out, Walk_Entry{sub = owned, kind = _file_type_name(fi.type)})
		if fi.type == .Directory {
			_walk_collect(root, owned, out) or_return
		}
	}
	return nil
}

// d:walk() -> iterator — returns (fn, state) for generic-for:
//   for sub, type in d:walk() do ... end
// The eager snapshot (see Walk_State note) means the loop may remove
// entries mid-walk without disturbing the iteration.
@(private = "file")
_dir_walk :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Dir_Value)(lua.L_checkudata(L, 1, DIR_MT))
	entries := make([dynamic]Walk_Entry, context.allocator)
	if werr := _walk_collect(self.root, "", &entries); werr != nil {
		for e in entries {delete(e.sub, context.allocator)}
		delete(entries)
		msg := fmt.tprintf("cannot walk '%s': %v", self.root, werr)
		return c.int(lua.L_error(L, "makac.fs: Dir: walk: %s", cstring(raw_data(msg))))
	}
	ud := (^Walk_State)(lua.newuserdata(L, c.size_t(size_of(Walk_State))))
	ud^ = Walk_State{entries = entries[:], idx = 0}
	lua.L_setmetatable(L, WALK_MT)
	// Return (fn, state): generic-for calls fn(state, nil) each step.
	lua.pushcclosure(L, _walk_next, 0)
	lua.insert(L, -2) // [state, fn] -> [fn, state]
	return 2
}

@(private = "file")
_walk_state_gc :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	st := (^Walk_State)(lua.L_checkudata(L, 1, WALK_MT))
	for e in st.entries {delete(e.sub, context.allocator)}
	delete(st.entries)
	st^ = {}
	return 0
}

@(private = "file")
_walk_next :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	st := (^Walk_State)(lua.L_checkudata(L, 1, WALK_MT))
	if st.idx >= len(st.entries) {
		lua.pushnil(L)
		return 1
	}
	e := st.entries[st.idx]
	st.idx += 1
	lua.pushlstring(L, cstring(raw_data(e.sub)), c.size_t(len(e.sub)))
	lua.pushlstring(L, cstring(raw_data(e.kind)), c.size_t(len(e.kind)))
	return 2
}
