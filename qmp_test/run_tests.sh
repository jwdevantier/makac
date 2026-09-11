#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
# Build the qmp test driver, start the fake QMP server (Unix + TCP), run the
# suite against both transports, and report results. Cleans up on exit.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK="$(mktemp -d)"
SOCK="$WORK/qmp.sock"
HOST=127.0.0.1
PORT="${QMP_TEST_PORT:-14555}"
BIN="$WORK/qmp_test"
LOG="$WORK/server.log"

cleanup() {
	[[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

echo "== building =="
odin build "$ROOT/qmp_test" -out:"$BIN"

echo "== starting fake QMP server (unix:$SOCK tcp:$HOST:$PORT) =="
python3 "$HERE/fake_qmp.py" "$SOCK" "$HOST" "$PORT" >"$LOG" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 100); do
	grep -q READY "$LOG" 2>/dev/null && break
	sleep 0.05
done
grep -q READY "$LOG" || { echo "server failed to start:"; cat "$LOG"; exit 1; }

status=0

echo "== Unix socket =="
if "$BIN" "$SOCK"; then echo "UNIX: OK"; else echo "UNIX: FAILED"; status=1; fi

echo "== TCP socket =="
if "$BIN" "$HOST:$PORT"; then echo "TCP: OK"; else echo "TCP: FAILED"; status=1; fi

exit $status
