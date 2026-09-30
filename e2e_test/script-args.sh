#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
#
# End-to-end guard for the implicit script form (design/cli.md): the first
# argument that is no subcommand runs as a workflow, and EVERYTHING after it
# reaches Lua's `arg` table verbatim — long flags keep their dashes, bundled
# short flags stay bundled, "-n5" passes through, and a '--' separator
# survives. Also pins SCRIPT_DIR/PROJECT_DIR, equivalence of 'makac run x'
# and 'makac x', and that running from a subdirectory still yields absolute
# directory globals.
#
# The workflow under test is echo_args.lua (next to this script), which
# echoes the script context globals in a stable format. Deliberately
# hermetic: the test needs nothing outside e2e_test/ and the binary.
#
#   script-args.sh /path/to/makac
set -euo pipefail

bin="${1:?usage: script-args.sh <makac-binary>}"
bin="$(readlink -f "$bin")"
if [ ! -x "$bin" ]; then
  echo "script-args: not executable: $bin" >&2
  exit 1
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# canonicalize: SCRIPT_DIR/PROJECT_DIR are absolute paths derived from the
# physical CWD, so compare against a symlink-free $work
work="$(readlink -f "$(mktemp -d)")"
trap 'rm -rf "$work"' EXIT

fail() { echo "script-args: $1" >&2; exit 1; }

# expect_out <name> <expected-stdout> <makac-args...>
# Runs `"$bin" <args...>` inside $work and compares stdout byte-for-byte.
# The whole invocation's output is compared so nothing (an extra warning,
# a dropped arg, ...) slips through unnoticed.
expect_out() {
  local name="$1" expected="$2"
  shift 2
  local got
  if ! got="$(cd "$work" && "$bin" "$@" 2>"$work/err.log")"; then
    fail "'makac $*' exited non-zero:
$(cat "$work/err.log")"
  fi
  [ -s "$work/err.log" ] || rm -f "$work/err.log"
  [ ! -e "$work/err.log" ] || fail "'makac $*' wrote to stderr:
$(cat "$work/err.log")"
  [ "$got" = "$expected" ] || fail "$name:
--- expected ---
$expected
--- got ---
$got
---"
}

"$bin" init "$work" >/dev/null || fail "'makac init' failed"
cp "$here/echo_args.lua" "$work/echo_args.lua"

# 1. implicit form: spaces-in-an-arg, a long flag and a non-letter "bundle"
#    all reach the script untouched.
expect_out "implicit form pass-through" "script:   echo_args.lua
args (4):
  [1] \"one\"
  [2] \"two words\"
  [3] \"--verbose\"
  [4] \"-n5\"
SCRIPT_DIR:  $work
PROJECT_DIR: $work" echo_args.lua one "two words" --verbose -n5

# 2. explicit 'run' form is identical, and bundled short flags stay bundled.
expect_out "run form equivalence" "script:   echo_args.lua
args (2):
  [1] \"same\"
  [2] \"-abc\"
SCRIPT_DIR:  $work
PROJECT_DIR: $work" run echo_args.lua same -abc

# 3. no arguments: arg[0] is still the script, the array part is empty.
expect_out "no script arguments" "script:   echo_args.lua
args (0):
SCRIPT_DIR:  $work
PROJECT_DIR: $work" echo_args.lua

# 4. '--': before the script it stops makac's own flag parsing; after the
#    script it is passed through verbatim (same convention as standalone lua).
expect_out "leading -- separator" "script:   echo_args.lua
args (1):
  [1] \"x\"
SCRIPT_DIR:  $work
PROJECT_DIR: $work" -- echo_args.lua x
expect_out "-- passed through to the script" "script:   echo_args.lua
args (2):
  [1] \"--\"
  [2] \"x\"
SCRIPT_DIR:  $work
PROJECT_DIR: $work" echo_args.lua -- x

# 5. from a subdirectory: arg[0] stays as given (relative), but SCRIPT_DIR
#    and PROJECT_DIR are absolute and both anchor at the project root.
mkdir -p "$work/sub"
got="$(cd "$work/sub" && "$bin" ../echo_args.lua 2>/dev/null)" \
  || fail "running from a subdirectory failed"
expected="script:   ../echo_args.lua
args (0):
SCRIPT_DIR:  $work
PROJECT_DIR: $work"
[ "$got" = "$expected" ] || fail "subdirectory run:
--- expected ---
$expected
--- got ---
$got
---"

# 6. SCRIPT_DIR and PROJECT_DIR really MAY differ: a script in a nested
#    directory of the project anchors SCRIPT_DIR at its own directory while
#    PROJECT_DIR stays at the project root.
cp "$here/echo_args.lua" "$work/sub/tool.lua"
expect_out "script in a nested project directory" "script:   sub/tool.lua
args (0):
SCRIPT_DIR:  $work/sub
PROJECT_DIR: $work" sub/tool.lua

echo "script-args: ok"
