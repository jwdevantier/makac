// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package argparse

import "core:log"
import "core:testing"

T :: testing.T

toks_eq :: proc(t: ^T, expected: []Token, actual: []Token) -> bool {
	if !testing.expectf(
		t,
		len(actual) == len(expected),
		"token length mismatch\n\texpected: {}\n\t     got: ({})",
		expected,
		actual,
	) {
		return false
	}
	ok := true
	for tok, ndx in actual {
		if !testing.expectf(
			t,
			tok == expected[ndx],
			"mismatch at {}; expected {}, got {}",
			ndx,
			expected[ndx],
			tok,
		) {
			ok = false
		}
	}
	return ok
}

// One row in the table.
Tokenize_Case :: struct {
	name:        string, // human-readable id, used in failure messages
	args:        []string, // input
	expected:    []Token, // expected tokens
	want_err_at: int, // if error, describes index of error
}

// `[...]` infers the length from the initializer — add/remove rows freely.
tokenize_cases :: [?]Tokenize_Case {
	{name = "empty", args = {}, expected = {}, want_err_at = -1},
	{
		name = "single word",
		args = {"hello"},
		expected = {Token{kind = .Word, text = "hello"}},
		want_err_at = -1,
	},
	{
		name = "two words",
		args = {"hello", "world"},
		expected = {Token{kind = .Word, text = "hello"}, Token{kind = .Word, text = "world"}},
		want_err_at = -1,
	},
	{
		name = "long flag",
		args = {"--flag"},
		expected = {Token{kind = .Long_Flag, text = "flag"}},
		want_err_at = -1,
	},
	{
		name = "short flag",
		args = {"-f"},
		expected = {Token{kind = .Short_Flag, text = "f"}},
		want_err_at = -1,
	},
	{
		name = "bundled short",
		args = {"-abc"},
		expected = {
			Token{kind = .Short_Flag, text = "a"},
			Token{kind = .Short_Flag, text = "b"},
			Token{kind = .Short_Flag, text = "c"},
		},
		want_err_at = -1,
	},
	{
		name = "end of opts",
		args = {"--"},
		expected = {Token{kind = .End_Of_Options, text = "--"}},
		want_err_at = -1,
	},
	{name = "bare dash", args = {"-"}, expected = {}, want_err_at = 0},
	{
		name = "nested command",
		args = {"-v", "--conf", "/tmp/conf", "build-img", "--force", "myimg"},
		expected = {
			Token{kind = .Short_Flag, text = "v"},
			Token{kind = .Long_Flag, text = "conf"},
			Token{kind = .Word, text = "/tmp/conf"},
			Token{kind = .Word, text = "build-img"},
			Token{kind = .Long_Flag, text = "force"},
			Token{kind = .Word, text = "myimg"},
		},
		want_err_at = -1,
	},
}

@(test)
test_tokenize :: proc(t: ^T) {
	for c in tokenize_cases {
		toks, err_at := tokenize(c.args)
		defer if err_at < 0 {delete(toks)}

		// `defer none` — just keep going so ALL failing rows are reported,
		// not just the first one. Don't early-return on failure.
		toks_eq(t, c.expected, toks[:])

		testing.expectf(
			t,
			err_at == c.want_err_at if err_at > -1 else true,
			"[{}] expected (err_at={}); got (err_at={})",
			c.name,
			c.want_err_at,
			err_at,
		)
	}
}

