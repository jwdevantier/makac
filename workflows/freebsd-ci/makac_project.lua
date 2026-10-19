-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- Project wiring for the FreeBSD CI demo (freebsd-ci.lua).
--
-- makac.qemu is fetched from GitHub, tracking its default branch (main).
-- The cloud-init builder features this workflow needs (compressed base
-- images, probed backing format, chained stage manifests) live there;
-- 'makac fetch' brings the checkout up to date. Pin `rev` to a commit if a
-- reproducible build matters more than tracking upstream.
return {
	inputs = {
		qemu = {
			fetcher = "fetchgit",
			with = {
				url = "https://github.com/jwdevantier/makac.qemu",
				rev = "main",
			},
		},
	},
	-- aliases are what workflows use: 'qemu:img' / 'qemu:vm' in a step's
	-- uses field, require("pkgs/qemu/...") in Lua
	packages = { qemu = "qemu" },
}
