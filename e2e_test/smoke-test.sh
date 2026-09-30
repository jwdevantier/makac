#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
#
# Exercise a built makac binary end to end: create a throwaway project, run a
# trivial step through the real Lua VM / prelude / step engine, then print the
# version. Used inside the release build container, and again from foreign
# base images to prove the artifact runs on a glibc it wasn't built against.
#
#   smoke-test.sh /path/to/makac
set -euo pipefail

bin="${1:?usage: smoke-test.sh <makac-binary>}"
bin="$(readlink -f "$bin")"
if [ ! -x "$bin" ]; then
  echo "smoke-test: not executable: $bin" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# `init` creates <work>/.makac and, beside it, makac_project.lua (plus the
# LuaLS stubs, best effort).
"$bin" init "$work" >/dev/null
[ -f "$work/makac_project.lua" ] || {
  echo "smoke-test: init did not create makac_project.lua" >&2
  exit 1
}

cat > "$work/hello.lua" <<'LUA'
step {
  name = "smoke",
  uses = "shell",
  with = { cmd = { "echo", "makac-smoke-ok" } },
}
LUA

# Running from inside the project resolves the .makac data dir by walking up.
( cd "$work" && "$bin" run hello.lua >/dev/null )

# The implicit form 'makac <workflow> [args...]' runs the workflow too,
# exposing the args and the SCRIPT_DIR/PROJECT_DIR globals (design/cli.md).
cat > "$work/ctx.lua" <<'LUA'
assert(SCRIPT_DIR ~= nil, "SCRIPT_DIR not set")
assert(PROJECT_DIR ~= nil, "PROJECT_DIR not set")
assert(arg ~= nil and arg[0] == "ctx.lua", "arg[0] mismatch")
assert(arg[1] == "a b" and arg[2] == "--flag" and arg[3] == "-xyz", "arg pass-through broken")
local f = assert(io.open(SCRIPT_DIR .. "/ctx-out.txt", "w"))
f:write(SCRIPT_DIR .. "\n" .. PROJECT_DIR .. "\n")
f:close()
LUA
( cd "$work" && "$bin" ctx.lua "a b" --flag -xyz >/dev/null )
{
  read -r got_script_dir
  read -r got_project_dir
} < "$work/ctx-out.txt"
[ "$got_script_dir" = "$work" ] || {
  echo "smoke-test: SCRIPT_DIR mismatch: '$got_script_dir' != '$work'" >&2
  exit 1
}
[ "$got_project_dir" = "$work" ] || {
  echo "smoke-test: PROJECT_DIR mismatch: '$got_project_dir' != '$work'" >&2
  exit 1
}

echo "smoke-test: ok ($("$bin" --version))"
