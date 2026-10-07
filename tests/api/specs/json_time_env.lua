-- specs/json_time_env.lua — makac.json / makac.time / makac.env / sha256 /
-- random_hex / _luals_stub in-VM.
-- Contracts: site/src/lua-api/makac-api.md; stub classes MakacJson/Time/Env.

local api = require("api")

api.group("json")

api.t("json", "scalar_and_structure_roundtrip", function()
	local back = makac.json.loads(makac.json.dumps({
		s = "text", i = 42, f = 1.5, b = false,
		arr = { "x", 2, true },
		nested = { k = { "v" } },
	}))
	api.eq(back.s, "text", "string")
	api.eq(back.i, 42, "integer")
	api.eq(back.f, 1.5, "float")
	api.eq(back.b, false, "false survives (distinct from nil)")
	api.eq(back.arr[1], "x", "array[1]")
	api.eq(back.arr[3], true, "array bool")
	api.eq(back.nested.k[1], "v", "nesting")
end)

api.t("json", "loads_scalars_and_containers", function()
	api.eq(makac.json.loads("42"), 42, "bare number")
	api.eq(makac.json.loads('"x"'), "x", "bare string")
	api.eq(makac.json.loads("null"), nil, "json null -> nil-ish")
	api.eq(makac.json.loads("[1,2]")[2], 2, "array")
	api.eq(makac.json.loads('{"a":1}').a, 1, "object")
end)

api.t("json", "dumps_empty_table_is_object", function()
	-- probed on reference: dumps({}) == "{}" (empty table -> object, not [])
	api.eq(makac.json.dumps({}), "{}", "empty table encodes as object (probed)")
end)

api.t("json", "dumps_rejects_mixed_tables", function()
	-- probed: {1, nil, 3} raises (hole => mixes array/non-array)
	api.raises(function() makac.json.dumps({ 1, nil, 3 }) end,
		"mixes array and non-array", "holey array table raises (probed)")
end)

api.t("json", "dumps_rejects_unencodable_and_loads_rejects_garbage", function()
	api.raises(function() makac.json.dumps({ f = print }) end, nil, "function value unencodable")
	api.raises(function() makac.json.loads("{ nope") end, nil, "garbage json raises")
end)

api.t("json", "unicode_and_control_chars_roundtrip", function()
	local back = makac.json.loads(makac.json.dumps({ s = "héllo → wörld\nline2\ttab" }))
	api.eq(back.s, "héllo → wörld\nline2\ttab", "utf8 + escapes survive")
end)

api.group("time")

api.t("time", "monotonic_integer_ns_and_constants", function()
	local a = makac.time.now()
	makac.time.sleep(makac.time.ns_per_ms)
	local b = makac.time.now()
	api.type_is(a, "number", "now() integer")
	api.truthy(b > a, "monotonic")
	api.truthy(b - a >= makac.time.ns_per_ms, "sleep lasted at least as long")
	api.eq(makac.time.ns_per_us, 1000, "ns_per_us")
	api.eq(makac.time.ns_per_ms, 1000000, "ns_per_ms")
	api.eq(makac.time.ns_per_s, 1000000000, "ns_per_s")
end)

api.t("time", "sleep_validation", function()
	api.raises(function() makac.time.sleep(-1) end, nil, "negative sleep raises")
	makac.time.sleep(0) -- zero is fine
end)

api.group("env")

api.t("env", "all_version_makac_path", function()
	local all = makac.env.all()
	api.type_is(all, "table", "env.all returns a table")
	api.eq(all.PATH ~= nil, true, "PATH present")
	local maj, min = makac.env.version() -- multiple returns!
	api.type_is(maj, "number", "version major integer")
	api.type_is(min, "number", "version minor integer")
	local p = makac.env.makac_path()
	api.neq(type(p), "string", "makac_path returns a path value (probed)")
	api.eq(makac.fs.stat(tostring(p)) == nil, false, "and the file exists")
end)

api.group("misc")

api.t("misc", "sha256_known_vectors_and_nul", function()
	api.eq(makac.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty")
	api.eq(makac.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc")
	api.neq(makac.sha256("a\0b"), makac.sha256("ab"), "NUL is significant in the input")
end)

api.t("misc", "random_hex", function()
	local a = makac.random_hex(16)
	api.eq(#a, 16, "length honored")
	api.matches(a, "^[0-9a-f]+$", "lowercase hex charset")
	api.neq(a, makac.random_hex(16), "two draws differ")
	api.raises(function() makac.random_hex(0) end, nil, "n must be positive")
end)

api.t("misc", "luals_stub_embedded", function()
	api.type_is(makac._luals_stub, "string", "stub baked into the binary")
	api.contains(makac._luals_stub, "---@class Makac", "looks like the LuaCATS stub")
end)
