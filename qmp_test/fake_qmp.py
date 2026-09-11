#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
"""Fake QMP server over both a Unix socket and a TCP socket, same protocol.

Usage: fake_qmp.py <unix-socket-path> [tcp-host] [tcp-port]

Protocol (one JSON object per line, driven by the commands we receive):
  - on connect: send the QMP greeting
  - {"execute":"qmp_capabilities"} -> {"return":{}}
  - {"execute":"query-status"}     -> two async events, then the return
  - {"execute":"query-block"}      -> {"return":[...]} (no events)
  - {"execute":"bad-cmd"}          -> {"error":{...}}
  - {"execute":"emit-event"}       -> one async event, then {"return":{}}
  - {"execute":"hang"}             -> never reply (exercises send() timeout)
  - any other {"execute":...}       -> {"return":{}}
"""
import json
import os
import socket
import sys
import threading

UNIX = sys.argv[1]
TCP_HOST = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
TCP_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 14555

GREETING = {"QMP": {"version": {"qemu": {"major": 8, "minor": 0, "micro": 0},
                                 "package": "fake"},
                    "capabilities": []}}


def handle(conn):
    f = conn.makefile("rw", encoding="utf-8", newline="\n")
    f.write(json.dumps(GREETING) + "\n")
    f.flush()

    def send(obj):
        f.write(json.dumps(obj) + "\n")
        f.flush()

    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        cmd = msg.get("execute")
        if cmd == "qmp_capabilities":
            send({"return": {}})
        elif cmd == "query-status":
            send({"event": "RTC_CHANGE", "data": {"offset": 1},
                  "timestamp": {"seconds": 1, "microseconds": 2}})
            send({"event": "SPICE_INITIALIZED", "data": {}})
            send({"return": {"status": "running", "running": True}})
        elif cmd == "query-block":
            send({"return": [{"device": "drive0", "type": "unknown"}]})
        elif cmd == "bad-cmd":
            send({"error": {"class": "CommandNotFound",
                            "desc": "The command bad-cmd has not been found"}})
        elif cmd == "emit-event":
            send({"event": "RESET", "data": {"guest": True}})
            send({"return": {}})
        elif cmd == "hang":
            pass
        else:
            send({"return": {}})
    conn.close()


def serve(sock):
    while True:
        conn, _ = sock.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if os.path.exists(UNIX):
    os.unlink(UNIX)
us = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
us.bind(UNIX)
us.listen(5)

ts = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
ts.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ts.bind((TCP_HOST, TCP_PORT))
ts.listen(5)

threading.Thread(target=serve, args=(us,), daemon=True).start()
threading.Thread(target=serve, args=(ts,), daemon=True).start()
print("READY", flush=True)
threading.Event().wait()
