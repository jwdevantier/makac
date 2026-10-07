-- specs/prelude.lua — the embedded-prelude DSL: defer/errdefer, the action
-- registry, step normalization, target wrappers and lifecycle.
-- Contracts: site/src/lua-api/workflow-dsl.md, concepts/targets.md,
-- reference/step.md. Behavior pinned by probing is marked.
--
-- NOTE on registry groups: define_action/redefine mutations are global, so
-- all names here carry the 'apitest' prefix to stay collision-free.

local api = require("api")

api.group("defer")

api.t("defer", "defer_runs_on_any_exit", function()
	local log = {}
	-- normal exit
	do
		local g <close> = makac.defer(function() log[#log + 1] = "normal" end)
	end
	-- error exit
	pcall(function()
		local g <close> = makac.defer(function() log[#log + 1] = "error" end)
		error("boom", 0)
	end)
	api.eq(table.concat(log, ","), "normal,error", "defer on both exits")
end)

api.t("defer", "errdefer_only_on_error_exit", function()
	local log = {}
	do
		local g <close> = makac.errdefer(function() log[#log + 1] = "normal-exit" end)
	end
	pcall(function()
		local g <close> = makac.errdefer(function() log[#log + 1] = "error-exit" end)
		error("boom", 0)
	end)
	api.eq(table.concat(log, ","), "error-exit", "errdefer skipped on normal exit")
end)

api.t("defer", "lifo_order_and_error_masking", function()
	local log = {}
	pcall(function()
		local a <close> = makac.defer(function() log[#log + 1] = "first-declared" end)
		local b <close> = makac.defer(function() log[#log + 1] = "second-declared" end)
	end)
	api.eq(table.concat(log, ","), "second-declared,first-declared", "LIFO close order")
	-- both are best-effort: an error in the cleanup cannot mask the unwinding
	local ok, err = pcall(function()
		local g <close> = makac.defer(function() error("cleanup-raises", 0) end)
		error("original", 0)
	end)
	api.eq(ok, false, "original error propagates")
	api.contains(tostring(err), "original", "cleanup error does not mask the original")
end)

api.group("registry")

api.t("registry", "define_run_normalize_roundtrip", function()
	makac.define_action("apitest_echo", function(with)
		return { changed = true, out = { got = with and with.msg or "none" } }
	end, { default_name = "echo a message" })
	local res = makac.run_action("apitest_echo", { msg = "hi" })
	api.eq(res.changed, true, "action's changed kept")
	api.eq(res.skipped, false, "skipped default filled")
	api.eq(res.err, nil, "err absent on success")
	api.eq(res.out.got, "hi", "with passed verbatim")
end)

api.t("registry", "define_action_redefine_is_error", function()
	makac.define_action("apitest_once", function() return {} end)
	api.raises(function()
		makac.define_action("apitest_once", function() return {} end)
	end, "already defined", "redefinition raises (probed)")
end)

api.t("registry", "run_action_unknown_and_bad_returns", function()
	api.raises(function() makac.run_action("apitest-ghost") end,
		"unknown action", "unknown name raises, naming it (probed)")
	makac.define_action("apitest_nil", function() return nil end)
	api.raises(function() makac.run_action("apitest_nil") end,
		"expected a result table", "nil return raises (probed)")
	makac.define_action("apitest_raise", function() error("inner", 0) end)
	local err = api.raises(function() makac.run_action("apitest_raise") end,
		nil, "raising action is wrapped")
	api.contains(tostring(err), "apitest_raise", "wrap names the action")
end)

api.t("registry", "normalize_result_fills_only_defaults", function()
	local n = makac.normalize_result({ out = { x = 1 } })
	api.eq(n.changed, false, "changed default")
	api.eq(n.skipped, false, "skipped default")
	api.eq(n.out.x, 1, "out preserved")
	api.eq(n.err, nil, "err untouched (absent)")
	local e = makac.normalize_result({ err = "bad" })
	api.eq(e.err, "bad", "err preserved verbatim")
end)

api.group("step")

api.t("step", "default_name_and_normalized_result", function()
	local res = step { uses = "apitest_echo", with = { msg = "m" } }
	api.eq(res.out.got, "m", "step returns the action result")
	-- failing action -> step raises naming step AND action
	makac.define_action("apitest_failer", function() return { err = "nope" } end)
	local err = api.raises(function()
		step { name = "doomstep", uses = "apitest_failer" }
	end, nil, "err result aborts the workflow")
	api.contains(tostring(err), "step 'doomstep'", "names the step")
	api.contains(tostring(err), "apitest_failer", "names the action")
end)

api.group("targets")

api.t("targets", "host_target_basics", function()
	local t = makac.host
	api.eq(makac.is_target(t), true, "host is a target")
	api.eq(t.kind, "host", "kind is host")
	api.eq(makac.is_target({}), false, "plain table is not a target")
	api.eq(makac.is_target(nil), false, "nil is not a target")
	local r = t:run({ "printf", "via-host" })
	api.eq(r.stdout, "via-host", "host:run captures")
	local r2 = t:run({ "false" })
	api.eq(r2.code, 1, "non-zero is data, no raise (probed)")
	-- probed: host:put/get exist and act as local copies
	local d = api.dir("tgt-host")
	makac.fs.write_file(d .. "/s", "copied")
	t:put(d .. "/s", d .. "/dst")
	api.eq(makac.fs.read_file(d .. "/dst"), "copied", "host:put copies locally")
	t:get(d .. "/dst", d .. "/dst2")
	api.eq(makac.fs.read_file(d .. "/dst2"), "copied", "host:get copies locally")
end)

api.t("targets", "make_target_validation_and_lifecycle", function()
	api.raises(function()
		makac.make_target("weird", "n", { run = function() end })
	end, "kind must be 'host' or 'remote'", "kinds are fixed (probed)")
	local closed = 0
	local t = makac.new_target({
		kind = "remote",
		name = "apitest-vt",
		run = function(argv, opts)
			return { code = 0, stdout = "ran:" .. argv[1], stderr = "" }
		end,
		close = function() closed = closed + 1 end,
	})
	api.eq(makac.is_target(t), true, "constructed target passes is_target")
	local r = t:run({ "mycmd" })
	api.eq(r.stdout, "ran:mycmd", "ops dispatched with argv")
	-- close idempotent; ops fail after close
	t:close()
	t:close()
	api.eq(closed, 1, "close folded to a single actual close")
	api.raises(function() t:run({ "x" }) end, nil, "run after close raises")
end)

api.t("targets", "new_target_missing_put_get_raise_not_supported", function()
	local t = makac.new_target({
		kind = "remote", name = "apitest-noput",
		run = function() return { code = 0, stdout = "", stderr = "" } end,
	})
	api.raises(function() t:put("a", "b") end, "does not support put", "put when undefined")
	api.raises(function() t:get("a", "b") end, "does not support get", "get when undefined")
	t:close()
end)

api.t("targets", "resolve_target_and_close_all", function()
	api.eq(makac.resolve_target({}), makac.host, "no target -> host")
	api.eq(makac.resolve_target({ target = makac.host }), makac.host, "honors with.target")
	local t = makac.new_target({
		kind = "remote", name = "apitest-ca",
		run = function() return { code = 0, stdout = "", stderr = "" } end,
	})
	makac.close_all_targets()
	api.raises(function() t:run({ "x" }) end, nil, "close_all closed it")
	-- NOTE probed: close_all_targets closes the HOST too ('closes every live
	-- target', findings.md). Nothing in later specs may use makac.host after
	-- this point.
end)

api.group("ssh_target_validation")

api.t("ssh_target_validation", "spec_validation_before_any_connection", function()
	-- probed: validation raises BEFORE _ssh_open, so no network/config happens
	api.raises(function() makac.new_ssh_target("", { host = "h", user = "u" }) end,
		"name must be a non-empty string", "empty name")
	api.raises(function() makac.new_ssh_target("n", nil) end,
		"spec must be a table", "missing spec")
	api.raises(function() makac.new_ssh_target("n", { user = "u" }) end,
		"spec.host must be a non-empty string", "missing host")
	api.raises(function() makac.new_ssh_target("n", { host = "h" }) end,
		"spec.user must be a non-empty string", "missing user")
end)
