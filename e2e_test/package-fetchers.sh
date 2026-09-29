#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
#
# End-to-end guard for PACKAGE-PROVIDED FETCHERS through the real CLI: a
# fetched package's manifest exports a fetcher ('foo:synth') that a *later*
# input uses to fetch another package ('bar'). This only works because
# `makac fetch` runs the provider's manifest mid-worklist and registers its
# fetchers under the provider's alias. It was silently broken once, so this
# fails loudly if it breaks again.
#
# Deliberately hermetic: no network, no git, no tar. The provider is used in
# place (filesystem fetcher) and its custom fetcher synthesizes the consumer
# package's manifest with makac.fs alone. The VM-level version of this check
# is test_fetch_worklist_storage_and_prune (vm/vm_test.odin); this one proves
# the same path through the shipped binary.
#
#   package-fetchers.sh /path/to/makac
set -euo pipefail

bin="${1:?usage: package-fetchers.sh <makac-binary>}"
bin="$(readlink -f "$bin")"
if [ ! -x "$bin" ]; then
  echo "package-fetchers: not executable: $bin" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A data directory + project file, so cwd data-dir resolution works.
"$bin" init "$work" >/dev/null

# The provider package (used in place). It exports one custom fetcher,
# 'synth', whose fetch writes the consumer's makac_package.lua from `tag`.
mkdir -p "$work/foo"
cat > "$work/foo/makac_package.lua" <<'LUA'
return {
  fetchers = {
    synth = {
      key = function(w)
        return "synth-" .. makac.sha256("synth\0" .. tostring(w.tag)):sub(1, 16)
      end,
      fetch = function(spec, dest)
        makac.fs.mkdir_p(dest)
        makac.fs.write_file(dest .. "/makac_package.lua",
          ("return { actions = { hello = function() return { out = { v = %q } } end } }")
            :format(tostring(spec.with.tag)))
      end,
    },
  },
}
LUA

# 'bar' is listed BEFORE its provider on purpose: file order must not matter.
# The worklist has to fetch foo, run its manifest, then resolve 'foo:synth'
# to fetch bar.
cat > "$work/makac_project.lua" <<LUA
return {
  inputs = {
    bar = { fetcher = "foo:synth", with = { tag = "bar-ok" } },
    foo = { fetcher = "filesystem", with = { path = "foo" } },
  },
  packages = { foo = "foo", bar = "bar" },
}
LUA

# 1. fetch: bar must be fetched *through* the provider's fetcher, after foo.
( cd "$work" && "$bin" fetch >fetch.log 2>&1 ) || {
  echo "package-fetchers: 'makac fetch' failed:" >&2
  cat "$work/fetch.log" >&2
  exit 1
}
grep -q "fetching bar via foo:synth" "$work/fetch.log" || {
  echo "package-fetchers: bar was not fetched via foo:synth:" >&2
  cat "$work/fetch.log" >&2
  exit 1
}

# 2. run: the synthesized package must load and its action must execute.
cat > "$work/wf.lua" <<'LUA'
local r = makac.run_action("bar:hello", {})
assert(r.out and r.out.v == "bar-ok",
  "bar:hello returned " .. tostring(r.out and r.out.v))
step { name = "provider-fetcher-chain", uses = "bar:hello", with = {} }
LUA
( cd "$work" && "$bin" run wf.lua >run.log 2>&1 ) || {
  echo "package-fetchers: 'makac run' failed:" >&2
  cat "$work/run.log" >&2
  exit 1
}

echo "package-fetchers: ok"
