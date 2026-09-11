// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "core:os"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:c"

import lua "vendor:lua/5.4"

// makac.fs — directories (design2/stdlib.md): mkdir_p and the moved listdir.

// makac.fs is a table carrying the two directory primitives; the flat
// makac.listdir alias still exists (the prelude enumerates packages with it)
// and IS the same function as makac.fs.listdir.
@(test)
test_fs_dirs_shape :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		assert(type(makac.fs) == "table", "makac.fs must be a table")
		assert(type(makac.fs.mkdir_p) == "function", "mkdir_p must be a function")
		assert(type(makac.fs.listdir) == "function", "listdir must be a function")
		assert(type(makac.listdir) == "function", "flat alias must exist")
		assert(makac.listdir == makac.fs.listdir, "alias must be the same function")
		`,
		"@fs_dirs_shape.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// mkdir_p creates nested directories (parents as needed).
@(test)
test_fs_mkdir_p_creates_nested :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "makac_fs_mkdirp_*", context.allocator)
	testing.expect(t, derr == nil, "temp dir")
	defer os.remove_all(dir)

	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string{
			`makac.fs.mkdir_p("`,
			dir,
			`/a/b/c")
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_fs_mkdir_p_creates_nested")
	if !ok {defer delete(err.message)}
	if !testing.expect(t, ok, "mkdir_p must succeed") {
		log_time_err(t, err)
		return
	}
	nested := strings.concatenate([]string{dir, "/a/b/c"}, context.temp_allocator)
	testing.expect(t, os.is_dir(nested), "a/b/c must exist and be a directory")
}

// mkdir_p on an existing directory is a no-op (no error), and a partial
// prefix of existing dirs is fine too.
@(test)
test_fs_mkdir_p_existing_is_noop :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "makac_fs_mkdirp_noop_*", context.allocator)
	testing.expect(t, derr == nil, "temp dir")
	defer os.remove_all(dir)
	sub := strings.concatenate([]string{dir, "/x"}, context.temp_allocator)
	testing.expect(t, os.make_directory(sub) == nil)
	// a file inside the existing dir proves the call did not clobber anything
	fpath := strings.concatenate([]string{sub, "/keep.txt"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file_from_string(fpath, "keep") == nil)

	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string{
			`makac.fs.mkdir_p("`,
			sub,
			`")
makac.fs.mkdir_p("`,
			sub,
			`/y/z")
-- calling twice is fine too
makac.fs.mkdir_p("`,
			sub,
			`/y/z")
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_fs_mkdir_p_existing_is_noop")
	if !ok {defer delete(err.message)}
	if !testing.expect(t, ok, "mkdir_p on existing dirs must not fail") {
		log_time_err(t, err)
		return
	}
	yz := strings.concatenate([]string{sub, "/y/z"}, context.temp_allocator)
	testing.expect(t, os.is_dir(yz), "y/z must have been created")
	data, _ := os.read_entire_file(fpath, context.temp_allocator)
	testing.expect(t, string(data) == "keep", "existing content must be untouched")
}

// mkdir_p raises when a path component is a regular file.
@(test)
test_fs_mkdir_p_raises_through_file :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "makac_fs_mkdirp_file_*", context.allocator)
	testing.expect(t, derr == nil, "temp dir")
	defer os.remove_all(dir)
	fpath := strings.concatenate([]string{dir, "/file"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file_from_string(fpath, "x") == nil)

	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string{
			`local ok1, e1 = pcall(makac.fs.mkdir_p, "`,
			fpath,
			`/sub")
assert(not ok1, "mkdir_p through a file must raise")
assert(e1:find("mkdir_p"), "error names the operation, got: " .. tostring(e1))
local ok2 = pcall(makac.fs.mkdir_p, "`,
			fpath,
			`")
assert(not ok2, "mkdir_p on top of a file must raise")
-- the file itself is untouched
local f = io.open("`,
			fpath,
			`", "r")
assert(f and f:read("a") == "x", "file content must be untouched")
if f then f:close() end
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_fs_mkdir_p_raises_through_file")
	if !ok {defer delete(err.message)}
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// makac.fs.listdir: entries carry correct name/is_dir; a missing directory
// returns nil + error message (absence is not an error — no raise).
@(test)
test_fs_listdir_via_submodule :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "makac_fs_listdir_*", context.allocator)
	testing.expect(t, derr == nil, "temp dir")
	defer os.remove_all(dir)
	sub := strings.concatenate([]string{dir, "/sub"}, context.temp_allocator)
	testing.expect(t, os.make_directory(sub) == nil)
	fpath := strings.concatenate([]string{dir, "/f.txt"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file_from_string(fpath, "x") == nil)

	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string{
			`local es, err = makac.fs.listdir("`,
			dir,
			`")
assert(err == nil, "no error expected for an existing dir")
assert(#es == 2, "expected 2 entries, got " .. #es)
local by_name = {}
for _, e in ipairs(es) do by_name[e.name] = e.is_dir end
assert(by_name["sub"] == true, "sub must be a dir")
assert(by_name["f.txt"] == false, "f.txt must be a file")
-- missing dir -> nil + error message (NOT a raised error)
local es2, err2 = makac.fs.listdir("`,
			dir,
			`/no-such-dir")
assert(es2 == nil and type(err2) == "string", "missing dir must return nil, err")
-- a regular file is not a directory either
local es3, err3 = makac.fs.listdir("`,
			fpath,
			`")
assert(es3 == nil and type(err3) == "string", "file must return nil, err")
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_fs_listdir_via_submodule")
	if !ok {defer delete(err.message)}
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// makac.fs — regular files and temp entries (design2/stdlib.md):
// read_file / write_file / stat / mktemp_dir / mktemp_file.

// read_file/write_file round-trip: write then read back the same bytes;
// read_file of a missing path is nil + err, of a directory is nil + err
// too; write_file raises when the target directory does not exist.
@(test)
test_fs_read_write_round_trip :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "makac_fs_rw_*", context.allocator)
	testing.expect(t, derr == nil, "temp dir")
	defer os.remove_all(dir)
	target := strings.concatenate([]string{dir, "/data.bin"}, context.temp_allocator)

	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string{
			`makac.fs.write_file("`,
			target,
			`", "hello\nworld")
local got = makac.fs.read_file("`,
			target,
			`")
assert(got == "hello\nworld", "round-trip mismatch: " .. tostring(got))
-- overwrite truncates
makac.fs.write_file("`,
			target,
			`", "abc")
assert(makac.fs.stat("`,
			target,
			`").size == 3, "size must be 3 after overwrite")
-- missing file -> nil, err (no raise)
local d, e = makac.fs.read_file("`,
			dir,
			`/no-such-file")
assert(d == nil and type(e) == "string", "missing file must give nil, err")
-- a directory is not a readable file either
local d2, e2 = makac.fs.read_file("`,
			dir,
			`")
assert(d2 == nil and type(e2) == "string", "directory read must give nil, err")
-- write into a missing directory raises
local ok3, e3 = pcall(makac.fs.write_file, "`,
			dir,
			`/gone/f", "x")
assert(not ok3 and tostring(e3):find("write_file"), "write must raise, got: " .. tostring(e3))
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_fs_read_write_round_trip")
	if !ok {defer delete(err.message)}
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// write_file{ atomic = true }: correct content, and NO temp litter in the
// directory afterwards; a failed atomic write (missing directory) also
// leaves nothing behind. A second atomic write replaces the first.
@(test)
test_fs_write_file_atomic :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "makac_fs_atomic_*", context.allocator)
	testing.expect(t, derr == nil, "temp dir")
	defer os.remove_all(dir)
	target := strings.concatenate([]string{dir, "/invocation"}, context.temp_allocator)

	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string{
			`makac.fs.write_file("`,
			target,
			`", "v1", { atomic = true })
assert(makac.fs.read_file("`,
			target,
			`") == "v1", "atomic write content")
-- overwrite atomically: replaces, never appends
makac.fs.write_file("`,
			target,
			`", "v2-longer", { atomic = true })
assert(makac.fs.read_file("`,
			target,
			`") == "v2-longer", "atomic replace content")
-- no temp litter: exactly one entry in the dir
local es = makac.fs.listdir("`,
			dir,
			`")
assert(#es == 1 and es[1].name == "invocation", "temp litter: " .. #es .. " entries")
-- failed atomic write into a missing dir raises...
local ok1, e1 = pcall(makac.fs.write_file, "`,
			dir,
			`/gone/f", "x", { atomic = true })
assert(not ok1 and tostring(e1):find("write_file"), "must raise: " .. tostring(e1))
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_fs_write_file_atomic")
	if !ok {defer delete(err.message)}
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
		return
	}
	// ... and the missing dir was not created as a side effect
	gone := strings.concatenate([]string{dir, "/gone"}, context.temp_allocator)
	_, serr := os.lstat(gone, context.temp_allocator)
	testing.expect(t, serr != nil, "failed atomic write must not create the dir")
	// no litter in `dir` itself either (already asserted in Lua; belt+braces
	// on the outer level in case the temp file landed a level up)
	fis, rerr := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expect(t, rerr == nil && len(fis) == 1, "dir must contain exactly the target")
}

// stat: kinds for file / dir / socket / link; size and integer mtime_ns;
// nil for a missing path (absence is an answer, not an error).
@(test)
test_fs_stat_kinds :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "makac_fs_stat_*", context.allocator)
	testing.expect(t, derr == nil, "temp dir")
	defer os.remove_all(dir)
	fpath := strings.concatenate([]string{dir, "/f.txt"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file_from_string(fpath, "12345") == nil)
	subdir := strings.concatenate([]string{dir, "/sub"}, context.temp_allocator)
	testing.expect(t, os.make_directory(subdir) == nil)
	lname := strings.concatenate([]string{dir, "/lnk"}, context.temp_allocator)
	testing.expect(t, os.symlink(fpath, lname) == nil)
	// a unix socket: bind + listen so the kernel creates the entry
	sock_path := strings.concatenate([]string{dir, "/s.sock"}, context.temp_allocator)
	fd := posix.socket(.UNIX, .STREAM, .IP)
	testing.expect(t, fd != -1, "socket()")
	addr: posix.sockaddr_un
	when ODIN_OS != .Linux {
		addr.sun_len = u8(size_of(posix.sockaddr_un))
	}
	addr.sun_family = .UNIX
	testing.expect(t, len(sock_path) <= len(addr.sun_path), "sock path too long")
	for i in 0 ..< len(sock_path) {addr.sun_path[i] = sock_path[i]}
	bres := posix.bind(fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr)))
	testing.expect(t, bres == .OK, "bind()")
	lres := posix.listen(fd, 1)
	testing.expect(t, lres == .OK, "listen()")
	defer posix.close(fd)

	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string{
			`local st = makac.fs.stat("`,
			fpath,
			`")
assert(st and st.type == "file", "file type, got: " .. tostring(st and st.type))
assert(st.size == 5, "file size 5, got: " .. tostring(st.size))
assert(math.type(st.mtime_ns) == "integer", "mtime_ns must be an integer")
assert(st.mtime_ns > 0, "mtime_ns positive")
local sd = makac.fs.stat("`,
			subdir,
			`")
assert(sd and sd.type == "dir", "dir type, got: " .. tostring(sd and sd.type))
local sk = makac.fs.stat("`,
			sock_path,
			`")
assert(sk and sk.type == "socket", "socket type, got: " .. tostring(sk and sk.type))
local sl = makac.fs.stat("`,
			lname,
			`")
assert(sl and sl.type == "link", "link type, got: " .. tostring(sl and sl.type))
-- missing path -> nil, and NOT an error (no raise)
assert(makac.fs.stat("`,
			dir,
			`/gone") == nil, "missing path must give nil")
local ok1 = pcall(makac.fs.stat, "`,
			dir,
			`/gone")
assert(ok1, "missing path must not raise")
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_fs_stat_kinds")
	if !ok {defer delete(err.message)}
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// stat on a path whose PARENT does not exist also gives nil (ENOENT), and
// stat on a dangling symlink reports "link" (lstat, not stat).
@(test)
test_fs_stat_missing_and_dangling :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "makac_fs_stat2_*", context.allocator)
	testing.expect(t, derr == nil, "temp dir")
	defer os.remove_all(dir)
	dangle := strings.concatenate([]string{dir, "/dangle"}, context.temp_allocator)
	testing.expect(t, os.symlink("/definitely/not/here", dangle) == nil)

	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string{
			`assert(makac.fs.stat("`,
			dir,
			`/gone/deeper") == nil, "ENOENT parent must give nil")
local sd = makac.fs.stat("`,
			dangle,
			`")
assert(sd and sd.type == "link", "dangling symlink is a link, got: " .. tostring(sd and sd.type))
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_fs_stat_missing_and_dangling")
	if !ok {defer delete(err.message)}
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// mktemp_dir: creates a real directory, mode 0700, incorporating the
// prefix, distinct across calls; no argument gives the default pattern.
@(test)
test_fs_mktemp_dir :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local d1 = makac.fs.mktemp_dir("makac-test-")
		local d2 = makac.fs.mktemp_dir("makac-test-")
		local d3 = makac.fs.mktemp_dir()
		assert(type(d1) == "userdata" and type(d2) == "userdata" and type(d3) == "userdata")
		assert(d1 ~= d2 and d1 ~= d3 and d2 ~= d3, "temp dirs must be distinct")
		assert(tostring(d1):find("makac%-test%-"), "prefix must appear in the name: " .. tostring(d1))
		for _, d in ipairs({ d1, d2, d3 }) do
			local st = makac.fs.stat(d)
			assert(st and st.type == "dir", "must be a dir: " .. tostring(d))
		end
		-- expose for the Odin side to inspect permissions
		_G.__mkd1, _G.__mkd2, _G.__mkd3 = d1, d2, d3
		`,
		"@fs_mktemp_dir.lua",
	)
	if !ok {defer delete(err.message)}
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
		return
	}
	names := []string{"__mkd1", "__mkd2", "__mkd3"}
	for name in names {
		lua.getglobal(v.state, strings.clone_to_cstring(name, context.temp_allocator))
		dn: c.size_t
		dp := lua.L_tostring(v.state, -1, &dn)
		d := _cstr(dp, dn)
		lua.pop(v.state, 2) // string + the pushed name copy
		fi, serr := os.lstat(d, context.temp_allocator)
		testing.expect(t, serr == nil, "temp dir exists")
		testing.expect(t, fi.type == .Directory, "is a dir")
		testing.expect(t, fi.mode == os.perm_number(0o700), "mode 0700")
		os.remove_all(d)
	}
}

// mktemp_file: creates an empty file, incorporating the prefix, distinct
// across calls, writable via io.open.
@(test)
test_fs_mktemp_file :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local f1 = makac.fs.mktemp_file("makac-tf-")
		local f2 = makac.fs.mktemp_file("makac-tf-")
		local f3 = makac.fs.mktemp_file()
		assert(f1 ~= f2 and f1 ~= f3, "temp files must be distinct")
		assert(tostring(f1):find("makac%-tf%-"), "prefix must appear in the name: " .. tostring(f1))
		for _, f in ipairs({ f1, f2, f3 }) do
			local st = makac.fs.stat(f)
			assert(st and st.type == "file" and st.size == 0, "empty file: " .. tostring(f))
		end
		-- fill it via io.open and read it back through makac.fs
		local h = assert(io.open(tostring(f1), "w"))
		h:write("staged")
		h:close()
		assert(makac.fs.read_file(f1) == "staged", "io.open must be able to fill it")
		_G.__mkf1, _G.__mkf2, _G.__mkf3 = f1, f2, f3
		`,
		"@fs_mktemp_file.lua",
	)
	if !ok {defer delete(err.message)}
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
		return
	}
	names := []string{"__mkf1", "__mkf2", "__mkf3"}
	for name in names {
		lua.getglobal(v.state, strings.clone_to_cstring(name, context.temp_allocator))
		fn2: c.size_t
		fp := lua.L_tostring(v.state, -1, &fn2)
		f := _cstr(fp, fn2)
		lua.pop(v.state, 2) // string + the pushed name copy
		os.remove(f)
	}
}

// makac.fs — hashing (design2/stdlib.md): sha256(path) -> hex | nil, err.

// Known vectors (sha256("") and sha256("abc")), the (nil, err) absence
// convention (a missing file and a directory are both unhashable), and a
// multi-MB file proving the hasher streams. Reference digests recomputed in
// Odin with the downloader's own streaming hasher (core:crypto/hash,
// load_at_once = false) — the same plumbing the binding runs.
@(test)
test_fs_sha256 :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "makac_fs_sha256_*", context.allocator)
	testing.expect(t, derr == nil, "temp dir")
	defer os.remove_all(dir)
	empty := strings.concatenate([]string{dir, "/empty"}, context.temp_allocator)
	abc := strings.concatenate([]string{dir, "/abc"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file_from_string(empty, "") == nil)
	testing.expect(t, os.write_entire_file_from_string(abc, "abc") == nil)
	big := strings.concatenate([]string{dir, "/big.bin"}, context.temp_allocator)
	big_n := 5 * 1024 * 1024 + 123 // odd size, not a chunk multiple
	{
		// deterministic pseudo-random content (no /dev/urandom dependency);
		// a simple LCG gives a non-trivial byte stream
		buf := make([]byte, 64 * 1024, context.temp_allocator)
		f, ferr := os.open(big, {.Write, .Create, .Trunc})
		testing.expect(t, ferr == nil, "open big")
		seed: u32 = 0x12345678
		written := 0
		for written < big_n {
			for i in 0 ..< len(buf) {
				seed = seed * 1664525 + 1013904223
				buf[i] = u8(seed >> 24)
			}
			n := min(len(buf), big_n - written)
			_, werr := os.write(f, buf[:n])
			testing.expect(t, werr == nil, "write big")
			written += n
		}
		os.close(f)
	}
	// the reference digest, computed with the same streaming hasher the
	// downloader uses (hash_file_by_name, load_at_once = false)
	raw, herr := hash.hash_file_by_name(.SHA256, big, false, context.temp_allocator)
	testing.expect(t, herr == nil, "reference hash")
	big_hex := string(hex.encode(raw, context.temp_allocator) or_else nil)

	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string{
			`-- the two classic NIST vectors
assert(makac.fs.sha256("`,
			empty,
			`") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
			"empty vector")
assert(makac.fs.sha256("`,
			abc,
			`") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
			"abc vector")
-- multi-MB file: streaming hasher (reference digest computed in Odin)
local h = makac.fs.sha256("`,
			big,
			`")
assert(h == "`,
			big_hex,
			`", "multi-MB digest mismatch: " .. tostring(h))
-- missing file -> nil, err, and NOT a raise
local d, e = makac.fs.sha256("`,
			dir,
			`/no-such-file")
assert(d == nil and type(e) == "string", "missing file must give nil, err")
local ok1 = pcall(makac.fs.sha256, "`,
			dir,
			`/gone")
assert(ok1, "missing file must not raise")
-- a directory is not hashable either
local d2, e2 = makac.fs.sha256("`,
			dir,
			`")
assert(d2 == nil and type(e2) == "string", "directory must give nil, err")
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_fs_sha256")
	if !ok {defer delete(err.message)}
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}
