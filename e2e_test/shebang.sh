#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
#
# End-to-end guard for SHEBANG scripts (design/cli.md): a Lua file with
# '#!/usr/bin/env makac' must be directly executable through the real
# kernel -> env -> makac chain. This exercises the full feature, not just
# the CLI fallback: makac must (a) skip the shebang line without shifting
# error line numbers, (b) run WITHOUT a data directory when the script
# lives outside any project, and (c) still resolve a project normally when
# the script is run from inside one.
#
# The system 'env' resolves 'makac' through PATH, so the binary under test
# is exposed via a shim directory prepended to PATH.
#
#   shebang.sh /path/to/makac
set -euo pipefail

bin="${1:?usage: shebang.sh <makac-binary>}"
bin="$(readlink -f "$bin")"
if [ ! -x "$bin" ]; then
  echo "shebang: not executable: $bin" >&2
  exit 1
fi

shim="$(mktemp -d)"                    # PATH shim for '/usr/bin/env makac'
proj="$(readlink -f "$(mktemp -d)")"   # a project (gets .makac via init)
plain="$(readlink -f "$(mktemp -d)")"  # NOT under $proj: no project here
trap 'rm -rf "$shim" "$proj" "$plain"' EXIT

ln -s "$bin" "$shim/makac"
runpath="$shim:$PATH"

fail() { echo "shebang: $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. the classic: hello world, executed directly, outside any project
cat > "$plain/hello.lua" <<'LUA'
#!/usr/bin/env makac
print("hello, world")
LUA
chmod +x "$plain/hello.lua"

got="$(cd "$plain" && PATH="$runpath" ./hello.lua)" \
  || fail "./hello.lua (outside a project) exited non-zero"
[ "$got" = "hello, world" ] || fail "expected 'hello, world', got: $got"

# 2. outside a project the script sees the data-dir-less context:
#    PROJECT_DIR is nil, SCRIPT_DIR and arg still work.
cat > "$plain/show.lua" <<'LUA'
#!/usr/bin/env makac
print("arg0=" .. tostring(arg and arg[0]))
print("arg1=" .. tostring(arg and arg[1]))
print("SCRIPT_DIR=" .. tostring(SCRIPT_DIR))
print("PROJECT_DIR=" .. tostring(PROJECT_DIR))
LUA
chmod +x "$plain/show.lua"

got="$(cd "$plain" && PATH="$runpath" ./show.lua extra)" \
  || fail "./show.lua exited non-zero"
expected="arg0=./show.lua
arg1=extra
SCRIPT_DIR=$plain
PROJECT_DIR=nil"
[ "$got" = "$expected" ] || fail "data-dir-less context:
--- expected ---
$expected
--- got ---
$got
---"

# 3. a script on PATH run by bare name: the kernel hands makac the resolved
#    PATH (never a bare word), so even a name matching a subcommand
#    ('doctor') cannot be shadowed.
mkdir -p "$plain/tools"
cat > "$plain/tools/doctor" <<'LUA'
#!/usr/bin/env makac
print("I am a script, not the subcommand")
print("SCRIPT_DIR=" .. tostring(SCRIPT_DIR))
LUA
chmod +x "$plain/tools/doctor"

got="$(cd "$plain" && PATH="$runpath:$plain/tools" doctor)" \
  || fail "PATH-resolved 'doctor' script exited non-zero"
expected="I am a script, not the subcommand
SCRIPT_DIR=$plain/tools"
[ "$got" = "$expected" ] || fail "script shadowing 'doctor':
--- expected ---
$expected
--- got ---
$got
---"
# ... while 'makac doctor' REMAINS the subcommand. NOTE: doctor exits
# non-zero and amends its banner ("== makac ==  N errors") when checks
# fail — minimal containers lack ssh/git/curl/... — so tolerate any exit
# code and ANY verdict: the banner's presence is what proves the doctor
# subcommand ran (a misrouted implicit-script attempt would instead fail
# with "cannot read file 'doctor'"). The first line is checked in bash,
# without 'head' (a pipe to it would be a pipefail/SIGPIPE trap).
out="$(cd "$proj" && PATH="$runpath" makac doctor 2>&1 || true)"
out="${out%%$'\n'*}"
case "$out" in
  *"== makac =="*) ;;
  *) fail "plain 'makac doctor' must still be the subcommand, got: $out" ;;
esac

# 4. error line numbers must match the file on disk: the error() call is on
#    line 3 (line 1 is the shebang).
cat > "$plain/boom.lua" <<'LUA'
#!/usr/bin/env makac

error("boom")
LUA

err="$(cd "$plain" && PATH="$runpath" "$bin" boom.lua 2>&1)" \
  && fail "boom.lua should have failed"
case "$err" in
  *boom.lua:3:*boom*) ;;
  *) fail "line number off (expected 'boom.lua:3: boom'), got: $err" ;;
esac

# 5. outside a project, data-dir-dependent functionality fails LOUDLY and
#    clearly instead of silently doing the wrong thing.
cat > "$plain/needdir.lua" <<'LUA'
#!/usr/bin/env makac
makac.load_packages()
LUA

err="$(cd "$plain" && PATH="$runpath" "$bin" needdir.lua 2>&1)" \
  && fail "needdir.lua should have failed"
case "$err" in
  *"no data directory"*) ;;
  *) fail "expected a clear 'no data directory' error, got: $err" ;;
esac

# 6. inside a project the SAME shebang script resolves the project by
#    walking up: PROJECT_DIR is set, loaded-package machinery active.
"$bin" init "$proj" >/dev/null || fail "'makac init' failed"
mkdir -p "$proj/deep/down"
cat > "$proj/deep/down/wf.lua" <<'LUA'
#!/usr/bin/env makac
print("SCRIPT_DIR=" .. tostring(SCRIPT_DIR))
print("PROJECT_DIR=" .. tostring(PROJECT_DIR))
LUA
chmod +x "$proj/deep/down/wf.lua"

got="$(cd "$proj/deep/down" && PATH="$runpath" ./wf.lua)" \
  || fail "shebang script inside a project exited non-zero"
expected="SCRIPT_DIR=$proj/deep/down
PROJECT_DIR=$proj"
[ "$got" = "$expected" ] || fail "project context:
--- expected ---
$expected
--- got ---
$got
---"

echo "shebang: ok"
