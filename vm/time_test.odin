// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "core:sys/posix"
import "core:testing"



// makac.time is a table hanging off the global makac table with the two
// functions and the three constants (integer-typed, exact values).
@(test)
test_time_shape_and_constants :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		assert(type(makac.time) == "table", "makac.time must be a table")
		assert(type(makac.time.sleep) == "function", "sleep must be a function")
		assert(type(makac.time.now) == "function", "now must be a function")
		assert(math.type(makac.time.ns_per_us) == "integer", "ns_per_us must be an integer")
		assert(math.type(makac.time.ns_per_ms) == "integer", "ns_per_ms must be an integer")
		assert(math.type(makac.time.ns_per_s) == "integer", "ns_per_s must be an integer")
		assert(makac.time.ns_per_us == 1000, "ns_per_us value")
		assert(makac.time.ns_per_ms == 1000000, "ns_per_ms value")
		assert(makac.time.ns_per_s == 1000000000, "ns_per_s value")
		`,
		"@time_shape.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// now() returns integer nanoseconds and never goes backwards.
@(test)
test_time_now_monotonic :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local a = makac.time.now()
		assert(math.type(a) == "integer", "now() must return an integer")
		assert(a > 0, "now() must be positive")
		local prev = a
		for _ = 1, 1000 do
			local cur = makac.time.now()
			assert(cur >= prev, "now() must be monotonic (non-decreasing)")
			prev = cur
		end
		makac.time.sleep(1 * makac.time.ns_per_ms)
		assert(makac.time.now() > a, "now() must advance across a sleep")
		`,
		"@time_now.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// sleep(0) and sub-millisecond sleeps work (no error, no hang).
@(test)
test_time_sleep_zero_and_sub_ms :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		makac.time.sleep(0)
		makac.time.sleep(1)            -- one nanosecond
		makac.time.sleep(500000)       -- half a millisecond
		makac.time.sleep(999 * makac.time.ns_per_us)
		`,
		"@time_sleep_small.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// sleep actually waits ~the requested span. Measured on the Odin side so a
// broken (no-op) sleep cannot pass by comparing now() against itself.
@(test)
test_time_sleep_duration :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	start := monotonic_ns()
	err, ok := run_string(v, `makac.time.sleep(50 * makac.time.ns_per_ms)`, "@sleep50.lua")
	defer delete(err.message)
	elapsed := monotonic_ns() - start
	if !testing.expect(t, ok, "expected sleep to succeed") {
		log_time_err(t, err)
		return
	}
	testing.expectf(
		t,
		elapsed >= 40_000_000,
		"50ms sleep returned too early: %d ns elapsed",
		elapsed,
	)
	testing.expectf(
		t,
		elapsed < 2_000_000_000,
		"50ms sleep took absurdly long: %d ns elapsed",
		elapsed,
	)
}

// Negative, absurd and non-integer inputs raise (errors-raise convention).
@(test)
test_time_sleep_bad_args_raise :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local ok1, e1 = pcall(makac.time.sleep, -1)
		assert(not ok1, "negative ns must raise")
		assert(type(e1) == "string" and e1:find("negative"), "error mentions negative")
		local ok2 = pcall(makac.time.sleep, 11 * 365 * 24 * 60 * 60 * makac.time.ns_per_s)
		assert(not ok2, "absurd ns must raise")
		local ok3 = pcall(makac.time.sleep, "soon")
		assert(not ok3, "string arg must raise")
		local ok4 = pcall(makac.time.sleep)
		assert(not ok4, "missing arg must raise")
		`,
		"@time_sleep_bad.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// Helpers ------------------------------------------------------------------

// CLOCK_MONOTONIC nanoseconds, measured outside the VM.
monotonic_ns :: proc() -> i64 {
	ts: posix.timespec
	posix.clock_gettime(.MONOTONIC, &ts)
	return i64(ts.tv_sec) * 1_000_000_000 + i64(ts.tv_nsec)
}

log_time_err :: proc(t: ^testing.T, err: Error) {
	testing.expectf(t, false, "lua error: %s", err.message)
}
