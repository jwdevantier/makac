// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package argparse

import "core:testing"
import "core:mem"

// One expected flag on the command that ends up being the "active" command.
Expected_Flag :: struct {
	name:  string,
	value: string,
}

// Inputs + expectations for a single parse run.
//
// `cmds`  are the expected `Parsed_Command.source.name` values, in order
//         (the implicit root command is always first).
// `flags` are the expected flags of the *last* command; checked only when `ok`.
// `has_pos` / `pos` describe the single `Parsed_Args` block, if any.
//
// On the error path (`ok == false`) only `err_kind` / `err_flag` are checked;
// `parse` already frees the result on error, so the result body is not inspected.
Parse_Case :: struct {
	name:     string, // human-readable id, used in failure messages
	args:     []string, // input argv (no program name; root command is implicit)
	ok:       bool, // expected return value of `parse`
	err_kind: Parse_Error_Kind, // expected `Parse_Error.kind`
	err_flag: string, // expected flag_name of the offending flag; "" => expect nil
	err_text: string, // expected text field of the error; "" => don't check
	cmds:     []string, // expected command names, in order
	flags:    []Expected_Flag, // expected flags of the last command (when ok)
	has_pos:  bool, // whether a Parsed_Args block is expected
	pos:      []string, // expected positional args (when has_pos)
}

// Shared command spec. Subcommands are referenced by pointer, so the spec
// values live at file scope as mutable globals; `&child_spec` stays valid and
// addressable for every test proc.
child_spec: Command = Command {
	name = "child",
	flags = []Flag {
		{short = "", long = "force", value = .None},
		{short = "o", long = "output", value = .Required},
	},
}

root_spec: Command = Command {
	name = "root",
	flags = []Flag {
		{short = "v", long = "verbose", value = .None},
		{short = "f", long = "conf", value = .Required},
	},
	commands = []^Command {&child_spec},
}

// --- helpers ---------------------------------------------------------------

slice_eq :: proc(t: ^T, label: string, expected, actual: []string) -> bool {
	ok := testing.expectf(
		t,
		len(actual) == len(expected),
		"[{}] length mismatch\n\texpected: {}\n\t     got: ({})",
		label,
		expected,
		actual,
	)
	if !ok {
		return false
	}
	for v, i in actual {
		if !testing.expectf(
			t,
			v == expected[i],
			"[{}] mismatch at {}; expected {}, got {}",
			label,
			i,
			expected[i],
			v,
		) {
			ok = false
		}
	}
	return ok
}

// Last Parsed_Command in the result, or `found=false` if there is none.
last_command :: proc(pr: Parse_Result) -> (pc: Parsed_Command, found: bool) {
	for e in pr {
		switch c in e {
		case Parsed_Command:
			pc = c
			found = true
		case Parsed_Args:
		}
	}
	return
}

// The single Parsed_Args block, if present.
find_args :: proc(pr: Parse_Result) -> (a: Parsed_Args, found: bool) {
	for e in pr {
		switch x in e {
		case Parsed_Command:
		case Parsed_Args:
			a = x
			found = true
		}
	}
	return
}

// Run one case end-to-end (tokenize -> parse -> assert).
//
// NOTE: `parse` deletes the result itself on the error path, so we only
// `delete_parse_result` when it succeeded.
expect_parse :: proc(t: ^T, c: Parse_Case, spec: ^Command) {
	toks, err_at := tokenize(c.args)
	defer if err_at < 0 { delete(toks) }
	if !testing.expectf(
		t, err_at < 0, "[{}] unexpected tokenize error at {}", c.name, err_at,
	) {
		return
	}

	pe: Parse_Error
	pr, ok := parse(spec, toks[:], &pe)
	defer if ok { delete_parse_result(pr) }

	if !testing.expectf(t, ok == c.ok, "[{}] expected ok={}, got ok={}", c.name, c.ok, ok) {
		return
	}
	if !testing.expectf(
		t, pe.kind == c.err_kind, "[{}] expected err_kind={}, got {}", c.name, c.err_kind, pe.kind,
	) {
		return
	}

	// offending flag, if any
	if c.err_flag != "" {
		got := pe.flag != nil ? flag_name(pe.flag) : ""
		testing.expectf(
			t, got == c.err_flag, "[{}] expected err_flag={}, got={}", c.name, c.err_flag, got,
		)
	} else {
		testing.expectf(
			t, pe.flag == nil, "[{}] expected no err_flag, got {}", c.name,
			pe.flag != nil ? flag_name(pe.flag) : "",
		)
	}

	// error text, if expected
	if c.err_text != "" {
		testing.expectf(
			t, pe.text == c.err_text, "[{}] expected err_text={}, got={}", c.name, c.err_text, pe.text,
		)
	}

	// On the error path the result has already been freed; stop here.
	if !ok {
		return
	}

	// command names, in order
	names: [dynamic]string
	defer delete(names)
	for e in pr {
		switch pc in e {
		case Parsed_Command:
			append(&names, pc.source.name)
		case Parsed_Args:
		}
	}
	slice_eq(t, c.name, c.cmds, names[:])

	// flags of the last command
	if len(c.flags) > 0 {
		lc, found := last_command(pr)
		if testing.expectf(t, found, "[{}] expected a command but found none", c.name) {
			for ef in c.flags {
				pf, present := lc.flags[ef.name]
				if testing.expectf(
					t, present, "[{}] expected flag {} to be present", c.name, ef.name,
				) {
					testing.expectf(
						t,
						pf.value == ef.value,
						"[{}] flag {} expected value {}, got {}",
						c.name,
						ef.name,
						ef.value,
						pf.value,
					)
				}
			}
			testing.expectf(
				t,
				len(lc.flags) == len(c.flags),
				"[{}] expected {} flag(s), got {}",
				c.name,
				len(c.flags),
				len(lc.flags),
			)
		}
	}

	// positional args block
	ap, found := find_args(pr)
	if c.has_pos {
		if testing.expectf(t, found, "[{}] expected a Parsed_Args block", c.name) {
			slice_eq(t, c.name, c.pos, ap.value[:])
		}
	} else {
		testing.expectf(t, !found, "[{}] expected no Parsed_Args block", c.name)
	}
}

// --- one @(test) proc per case ---------------------------------------------
// Each can be run on its own:
//   odin test argparse -define:ODIN_TEST_NAMES=argparse.test_parse_<name>

@(test)
test_parse_empty :: proc(t: ^T) {
	expect_parse(t, Parse_Case{name = "empty", args = {}, ok = true, err_kind = .None, cmds = {"root"}}, &root_spec)
}

@(test)
test_parse_boolean_long_flag :: proc(t: ^T) {
	expect_parse(
		t,
		Parse_Case{
			name = "boolean long flag",
			args = {"--verbose"},
			ok = true,
			err_kind = .None,
			cmds = {"root"},
			flags = {Expected_Flag{name = "verbose", value = ""}},
		},
		&root_spec,
	)
}

@(test)
test_parse_boolean_short_flag :: proc(t: ^T) {
	expect_parse(
		t,
		Parse_Case{
			name = "boolean short flag",
			args = {"-v"},
			ok = true,
			err_kind = .None,
			cmds = {"root"},
			flags = {Expected_Flag{name = "verbose", value = ""}},
		},
		&root_spec,
	)
}

@(test)
test_parse_required_short_flag_with_value :: proc(t: ^T) {
	expect_parse(
		t,
		Parse_Case{
			name = "required short flag with value",
			args = {"-f", "val.txt"},
			ok = true,
			err_kind = .None,
			cmds = {"root"},
			flags = {Expected_Flag{name = "conf", value = "val.txt"}},
		},
		&root_spec,
	)
}

@(test)
test_parse_required_long_flag_with_value :: proc(t: ^T) {
	expect_parse(
		t,
		Parse_Case{
			name = "required long flag with value",
			args = {"--conf", "val.txt"},
			ok = true,
			err_kind = .None,
			cmds = {"root"},
			flags = {Expected_Flag{name = "conf", value = "val.txt"}},
		},
		&root_spec,
	)
}

@(test)
test_parse_subcommand_with_flag_and_positional :: proc(t: ^T) {
	expect_parse(
		t,
		Parse_Case{
			name = "subcommand with flag and positional",
			args = {"child", "--force", "sub-pos.txt"},
			ok = true,
			err_kind = .None,
			cmds = {"root", "child"},
			flags = {Expected_Flag{name = "force", value = ""}},
			has_pos = true,
			pos = {"sub-pos.txt"},
		},
		&root_spec,
	)
}

@(test)
test_parse_subcommand_required_flag_with_value :: proc(t: ^T) {
	expect_parse(
		t,
		Parse_Case{
			name = "subcommand required flag with value",
			args = {"child", "-o", "out.bin"},
			ok = true,
			err_kind = .None,
			cmds = {"root", "child"},
			flags = {Expected_Flag{name = "output", value = "out.bin"}},
		},
		&root_spec,
	)
}

@(test)
test_parse_positional_args_only :: proc(t: ^T) {
	expect_parse(
		t,
		Parse_Case{
			name = "positional args only",
			args = {"foo", "bar"},
			ok = true,
			err_kind = .None,
			cmds = {"root"},
			has_pos = true,
			pos = {"foo", "bar"},
		},
		&root_spec,
	)
}

@(test)
test_parse_end_of_options_marker :: proc(t: ^T) {
	expect_parse(
		t,
		Parse_Case{
			name = "end of options marker",
			args = {"--", "pos.txt", "--not-a-flag"},
			ok = true,
			err_kind = .None,
			cmds = {"root"},
			has_pos = true,
			pos = {"pos.txt", "--not-a-flag"},
		},
		&root_spec,
	)
}

@(test)
test_parse_unknown_flag :: proc(t: ^T) {
	expect_parse(
		t,
		Parse_Case{name = "unknown flag", args = {"--bogus"}, ok = false, err_kind = .Unknown_Flag, err_text = "bogus"},
		&root_spec,
	)
}

@(test)
test_parse_missing_arg_at_end_of_input :: proc(t: ^T) {
	expect_parse(
		t,
		Parse_Case{
			name = "missing arg at end of input",
			args = {"-f"},
			ok = false,
			err_kind = .Missing_Arg,
			err_flag = "conf",
		},
		&root_spec,
	)
}

@(test)
test_parse_missing_arg_followed_by_another_flag :: proc(t: ^T) {
	expect_parse(
		t,
		Parse_Case{
			name = "missing arg followed by another flag",
			args = {"--conf", "--verbose"},
			ok = false,
			err_kind = .Missing_Arg,
			err_flag = "conf",
		},
		&root_spec,
	)
}

// --- parse_args (combined) tests -------------------------------------------

@(test)
test_parse_args_happy :: proc(t: ^T) {
	pe: Parse_Error
	pr, ok := parse_args(&root_spec, {"-v", "-f", "conf.txt", "child", "--force", "pos.txt"}, &pe)
	defer if ok { delete_parse_result(pr) }

	testing.expect(t, ok)
	if !ok { return }

	// check command names: root, child
	names: [dynamic]string
	defer delete(names)
	for e in pr {
		switch pc in e {
		case Parsed_Command:
			append(&names, pc.source.name)
		case Parsed_Args:
		}
	}
	testing.expectf(t, len(names) == 2, "expected 2 commands, got %v", names[:])
	testing.expect(t, names[0] == "root")
	testing.expect(t, names[1] == "child")

	// root has verbose and conf flags
	root_cmd := pr[0].(Parsed_Command)
	vf, vf_ok := root_cmd.flags["verbose"]
	testing.expect(t, vf_ok && vf.value == "")
	cf, cf_ok := root_cmd.flags["conf"]
	testing.expect(t, cf_ok && cf.value == "conf.txt")

	// child has force flag
	child_cmd := pr[1].(Parsed_Command)
	ff, ff_ok := child_cmd.flags["force"]
	testing.expect(t, ff_ok && ff.value == "")

	// positional args
	for e in pr {
		switch a in e {
		case Parsed_Args:
			testing.expectf(t, len(a.value) == 1, "expected 1 positional, got %v", a.value[:])
			testing.expect(t, a.value[0] == "pos.txt")
		case Parsed_Command:
		}
	}
}

@(test)
test_parse_args_invalid_arg :: proc(t: ^T) {
	pe: Parse_Error
	pr, ok := parse_args(&root_spec, {"-v", "-"}, &pe)
	testing.expect(t, !ok)
	testing.expect(t, pe.kind == .Invalid_Arg)
	testing.expect(t, pe.at == 1)
	testing.expect(t, pe.text == "-")
}

@(test)
test_parse_args_no_leaks :: proc(t: ^T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	pe: Parse_Error
	pr, ok := parse_args(
		&root_spec,
		{"-v", "-f", "conf.txt", "child", "-o", "out.bin", "pos"},
		&pe,
		perm = alloc,
		temp = alloc,
	)
	testing.expect(t, ok)
	if ok { delete_parse_result(pr) }

	testing.expectf(
		t,
		len(track.allocation_map) == 0,
		"leaked %d allocations",
		len(track.allocation_map),
	)
}