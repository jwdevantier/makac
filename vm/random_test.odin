// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
package vm

import "base:runtime"
import "core:fmt"
import "core:testing"

import lua "vendor:lua/5.4"

// makac.random_hex (design2/stdlib.md, "Misc (flat)") — exactly n lowercase
// hex chars from core:crypto's CSPRNG; two calls differ; odd n works.

@(test)
test_random_hex_shape_and_charset :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	// 12 chars: even n; charset exactly [0-9a-f]; length exactly n.
	err, ok := run_string(
		v,
		`
		h = makac.random_hex(12)
		assert(type(h) == "string", "random_hex must return a string")
		assert(#h == 12, "length must be n")
		assert(h:match("^[0-9a-f]+$") ~= nil, "charset must be [0-9a-f]")
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok) {
		log_time_err(t, err)
	}
}

@(test)
test_random_hex_odd :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	// Odd n truncates the ceil(n/2) hex pair to exactly n chars.
	err, ok := run_string(
		v,
		`
		h = makac.random_hex(7)
		assert(#h == 7, "odd n must still return exactly n chars")
		assert(h:match("^[0-9a-f]+$") ~= nil, "charset must be [0-9a-f]")
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok) {
		log_time_err(t, err)
	}
}

@(test)
test_random_hex_distinct :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	// Two 16-char draws colliding is impossible absent a broken CSPRNG.
	err, ok := run_string(
		v,
		`
		a = makac.random_hex(16)
		b = makac.random_hex(16)
		assert(a ~= b, "two draws must differ")
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok) {
		log_time_err(t, err)
	}
}

@(test)
test_random_hex_non_positive_raises :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	bad := []string{`makac.random_hex(0)`, `makac.random_hex(-4)`}
	for src in bad {
		err, ok := run_string(v, src)
		testing.expect(t, !ok, fmt.tprintf("`%s` must raise", src))
		testing.expect(t, len(err.message) > 0, "raise must carry a message")
		delete(err.message)
	}
}
