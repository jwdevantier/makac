// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
// Test driver for the qmp package against a fake QMP server.
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import qmp "../qmp"

failures := 0

check :: proc(cond: bool, name: string) {
	if cond {
		fmt.printfln("PASS: %s", name)
	} else {
		fmt.printfln("FAIL: %s", name)
		failures += 1
	}
}

logger :: proc(msg: string) {
	fmt.printfln("   [log] %s", msg)
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	code := run()

	if len(track.allocation_map) > 0 {
		fmt.eprintfln("=== %v allocations leaking! ===", len(track.allocation_map))
		for _, entry in track.allocation_map {
			fmt.eprintfln("- %v bytes @ %v", entry.size, entry.location)
		}
		code = 1
	} else {
		fmt.printfln("no leaks")
	}
	mem.tracking_allocator_destroy(&track)
	os.exit(code)
}

run :: proc() -> int {
	if len(os.args) < 2 {
		fmt.eprintfln("usage: %s <socket-path>", os.args[0])
		return 2
	}
	target := os.args[1]

	// --- connect (Unix path or TCP host:port, chosen by argument form) ---
	client: qmp.Client
	cerr: qmp.Error
	if strings.contains(target, ":") {
		client, cerr = qmp.connect_tcp(target, 5 * time.Second, context.allocator, logger)
	} else {
		client, cerr = qmp.connect(target, 5 * time.Second, context.allocator, logger)
	}
	check(cerr == .None, "connect succeeds")
	check(qmp.connected(&client), "client reports connected")
	if cerr != .None {
		return 1
	}

	// --- send query-status (emits 2 events before reply) ---
	reply, serr := qmp.send(&client, `{"execute":"query-status"}`, 5 * time.Second)
	check(serr == .None, "send query-status: no error")
	check(reply.ok, "send query-status: reply.ok")
	check(len(reply.return_json) > 0, "send query-status: has return payload")
	fmt.printfln("   return_json = %s", reply.return_json)

	// events buffered during send
	evs := qmp.events(&client)
	check(len(evs) == 2, "events() after query-status returns 2 events")
	if len(evs) == 2 {
		check(evs[0].name == "RTC_CHANGE", "first event is RTC_CHANGE")
		check(evs[1].name == "SPICE_INITIALIZED", "second event is SPICE_INITIALIZED")
	}
	for e in evs {
		delete(e.name)
		delete(e.raw)
	}
	delete(evs)

	// events cleared after drain
	evs2 := qmp.events(&client)
	check(len(evs2) == 0, "events() cleared after call")
	delete(evs2)

	// --- send query-block (no events) ---
	r2, s2 := qmp.send(&client, `{"execute":"query-block"}`, 5 * time.Second)
	check(s2 == .None, "send query-block: no error")
	check(r2.ok, "send query-block: reply.ok")
	evs3 := qmp.events(&client)
	check(len(evs3) == 0, "no events after query-block")
	delete(evs3)

	// --- error reply ---
	r3, s3 := qmp.send(&client, `{"execute":"bad-cmd"}`, 5 * time.Second)
	check(s3 == .None, "send bad-cmd: transport ok")
	check(!r3.ok, "send bad-cmd: reply not ok")
	check(r3.err.class == "CommandNotFound", "send bad-cmd: error class captured")
	fmt.printfln("   err.class=%s err.desc=%s", r3.err.class, r3.err.desc)

	// --- poll(): emit an event out-of-band via emit-event, then poll ---
	r4, s4 := qmp.send(&client, `{"execute":"emit-event"}`, 5 * time.Second)
	check(s4 == .None && r4.ok, "send emit-event ok")
	// the RESET event was emitted *before* the reply, so it is in the buffer.
	evs4 := qmp.events(&client)
	check(len(evs4) == 1 && evs4[0].name == "RESET", "emit-event buffered RESET")
	for e in evs4 { delete(e.name); delete(e.raw) }
	delete(evs4)

	// poll with nothing pending: should return promptly, no error, no events
	drained, perr := qmp.poll(&client, 100 * time.Millisecond)
	check(perr == .None, "poll with no data: no error (timeout is benign)")
	check(len(drained) == 0, "poll with no data: drains nothing")
	delete(drained)

	// consume: drop the n oldest buffered events, they stay gone
	r5, s7 := qmp.send(&client, `{"execute":"query-status"}`, 5* time.Second)
	check(s7 == .None && r5.ok, "send query-status again ok")
	qmp.consume(&client, 1)
	evs5 := qmp.events(&client)
	check(len(evs5) == 1 && evs5[0].name == "SPICE_INITIALIZED",
	      "consume(1) dropped only the oldest event")
	for e in evs5 { delete(e.name); delete(e.raw) }
	delete(evs5)
	qmp.consume(&client, 9) // over-count clamps: drops the remaining event
	evs6 := qmp.events(&client)
	check(len(evs6) == 0, "consume(9) on 1 event: clamps, buffer empty")
	delete(evs6)

	// --- send timeout (server hangs) ---
	_, s5 := qmp.send(&client, `{"execute":"hang"}`, 300 * time.Millisecond)
	check(s5 == .Timeout, "send hang: times out (VM unresponsive)")

	// --- close ---
	qmp.close(&client)
	check(!qmp.connected(&client), "close: disconnected")

	// operations after close report Not_Connected
	_, s6 := qmp.send(&client, `{"execute":"query-status"}`, time.Second)
	check(s6 == .Not_Connected, "send after close: Not_Connected")

	fmt.printfln("\n%d failure(s)", failures)
	return 1 if failures > 0 else 0
}
