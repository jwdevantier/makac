-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- specs/fs.lua — makac.fs.* in-VM, including edge cases pinned by probing
-- the reference binary (noted inline).
-- Contracts: site/src/lua-api/makac-api.md ("makac.fs.*").

local api = require("api")

api.group("fs")

api.t("fs", "mkdir_p_idempotent_and_deep", function()
	local d = api.dir("fs-mkdir")
	makac.fs.mkdir_p(d .. "/a/b/c")
	makac.fs.mkdir_p(d .. "/a/b/c") -- existing dir is fine
	api.eq(makac.fs.stat(d .. "/a/b/c").type, "dir", "deep dir created")
end)

api.t("fs", "write_read_roundtrip_with_nul_bytes", function()
	local d = api.dir("fs-rw")
	makac.fs.write_file(d .. "/bin.dat", "a\0b\0c")
	local got = makac.fs.read_file(d .. "/bin.dat")
	api.eq(got, "a\0b\0c", "binary content with NULs survives the roundtrip")
end)

api.t("fs", "write_file_needs_existing_parent", function()
	local d = api.dir("fs-wp")
	api.raises(function() makac.fs.write_file(d .. "/no/such/f", "x") end,
		"write_file", "missing parent raises (probed on reference)")
end)

api.t("fs", "absence_is_data_not_errors", function()
	local d = api.dir("fs-absent")
	local content, err1 = makac.fs.read_file(d .. "/nope")
	api.eq(content, nil, "read_file of missing: nil")
	api.type_is(err1, "string", "read_file of missing: error string")
	local entries, err2 = makac.fs.listdir(d .. "/nope")
	api.eq(entries, nil, "listdir of missing: nil")
	api.type_is(err2, "string", "listdir of missing: error string")
	api.eq(makac.fs.stat(d .. "/nope"), nil, "stat of missing: nil (no error)")
	local hash, err3 = makac.fs.sha256(d .. "/nope")
	api.eq(hash, nil, "sha256 of missing: nil")
	api.type_is(err3, "string", "sha256 of missing: error string")
	api.eq(makac.fs.read_file(d), nil, "read_file of a directory: nil (probed)")
end)

api.t("fs", "stat_fields", function()
	local d = api.dir("fs-stat")
	makac.fs.write_file(d .. "/f", "12345")
	local st = makac.fs.stat(d .. "/f")
	api.eq(st.type, "file", "type file")
	api.eq(st.size, 5, "size in bytes")
	api.type_is(st.mtime_ns, "number", "mtime_ns integer")
	makac.fs.mkdir_p(d .. "/dd")
	api.eq(makac.fs.stat(d .. "/dd").type, "dir", "type dir")
	makac.fs.symlink(d .. "/f", d .. "/ln")
	api.eq(makac.fs.stat(d .. "/ln").type, "link", "type link (lstat)")
end)

api.t("fs", "listdir_entries", function()
	local d = api.dir("fs-list")
	makac.fs.mkdir_p(d .. "/sub")
	makac.fs.write_file(d .. "/f", "x")
	local entries = makac.fs.listdir(d)
	api.eq(#entries, 2, "two entries")
	local seen = {}
	for _, e in ipairs(entries) do seen[e.name] = e.is_dir end
	api.eq(seen.sub, true, "dir flagged is_dir=true")
	api.eq(seen.f, false, "file flagged is_dir=false")
	local empty = makac.fs.listdir(d .. "/sub")
	api.eq(#empty, 0, "empty dir lists zero entries (probed: {} not nil)")
end)

api.t("fs", "symlink_creates_and_replaces", function()
	local d = api.dir("fs-link")
	makac.fs.write_file(d .. "/a", "1")
	makac.fs.write_file(d .. "/b", "2")
	makac.fs.symlink(d .. "/a", d .. "/l")
	api.eq(makac.fs.read_file(d .. "/l"), "1", "symlink resolves to first target")
	makac.fs.symlink(d .. "/b", d .. "/l") -- replacement, not error
	api.eq(makac.fs.read_file(d .. "/l"), "2", "symlink replaced")
	-- documented guard: replacing a NON-EMPTY directory must fail (no clobber)
	makac.fs.mkdir_p(d .. "/realdir/inner")
	api.raises(function() makac.fs.symlink(d .. "/a", d .. "/realdir") end,
		nil, "won't replace a non-empty directory")
end)

api.t("fs", "atomic_write", function()
	local d = api.dir("fs-atomic")
	makac.fs.write_file(d .. "/f", "v1", { atomic = true })
	makac.fs.write_file(d .. "/f", "v2", { atomic = true })
	api.eq(makac.fs.read_file(d .. "/f"), "v2", "atomic write replaced content")
	api.eq(#makac.fs.listdir(d), 1, "no temp file left behind")
end)

api.t("fs", "mktemp_under_system_tmp_with_prefix", function()
	-- probed: honors $TMPDIR (nix-shell sets it); falls back to /tmp
	local tmpdir = os.getenv("TMPDIR") or "/tmp"
	local pat = "^" .. tmpdir:gsub("%W", "%%%0") .. "[/]?bbpref"
	local dirp = tostring(makac.fs.mktemp_dir("bbpref"))
	api.matches(dirp, pat, "mktemp_dir: system tmp + prefix, returns path")
	api.eq(makac.fs.stat(dirp).type, "dir", "mktemp_dir creates a directory")
	local filep = tostring(makac.fs.mktemp_file("bbpref"))
	api.matches(filep, pat, "mktemp_file: system tmp + prefix")
	api.eq(makac.fs.stat(filep).type, "file", "mktemp_file creates an empty file")
	makac.fs.write_file(filep, "filled") -- caller fills/removes
end)

api.t("fs", "constants", function()
	api.eq(makac.fs.sep, "/", "path separator")
	api.eq(tostring(makac.fs.null_file()), "/dev/null", "null device")
end)
