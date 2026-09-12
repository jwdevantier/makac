// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause

package argparse

import "base:runtime"

Parsed_Flag :: struct {
	source: ^Flag,
	value:  string,
}

Parsed_Command :: struct {
	source: ^Command,
	flags:  map[string]Parsed_Flag,
}

Parsed_Args :: struct {
	value: [dynamic]string,
}

Parsed :: union #no_nil {
	Parsed_Command,
	Parsed_Args,
}

Parse_Result :: [dynamic]Parsed

Parse_Error_Kind :: enum {
	None,
	Invalid_Arg,
	Unknown_Flag,
	Missing_Arg,
}

Parse_Error :: struct {
	kind: Parse_Error_Kind,
	cmd:  ^Command,
	flag: ^Flag,
	text: string,  // offending arg (Invalid_Arg) or flag name (Unknown_Flag)
	at:   int,     // index into args for Invalid_Arg; -1 otherwise
}

delete_parse_result :: proc(pr: Parse_Result) {
	for e in pr {
		switch v in e {
		case Parsed_Command:
			delete(v.flags)
		case Parsed_Args:
			delete(v.value)
		}
	}
	delete(pr)
}

parse :: proc(
	spec: ^Command,
	tokens: []Token,
	err: ^Parse_Error,
	a: runtime.Allocator = context.allocator,
) -> (
	res: Parse_Result,
	ok: bool,
) {
	res = make([dynamic]Parsed, a)
	_err: Parse_Error = {}
	defer if !ok {
		delete_parse_result(res)
		if err != nil {
			err^ = _err
		}
	}
	ok = true

	pending: ^Flag = nil
	cmd: ^Command = spec
	pcmd: Parsed_Command = Parsed_Command {
		source = cmd,
		flags  = make(map[string]Parsed_Flag, a),
	}
	do_append := true
	token_loop: for tok, ndx in tokens {
		// last token parsed was a flag needing a value
		if pending != nil {
			if tok.kind != .Word {
				ok = false
				_err = Parse_Error {
					kind = .Missing_Arg,
					cmd  = cmd,
					flag = pending,
				}
				return
			} else {
				pcmd.flags[flag_name(pending)] = Parsed_Flag {
					source = pending,
					value  = tok.text,
				}
				pending = nil
				continue
			}
		}

		switch tok.kind {
		case .End_Of_Options:
			append(&res, pcmd)
			do_append = false
			args := Parsed_Args {
				value = make([dynamic]string, a),
			}
			for tok in tokens[ndx + 1:] {
				append(&args.value, tok.text)
			}
			append(&res, args)
			break token_loop
		case .Short_Flag:
			f: ^Flag = nil
			for &ff in cmd.flags {
				if (ff.short == tok.text) {
					f = &ff
					break
				}
			}
			if f == nil {
				ok = false
				_err = Parse_Error {
					kind = .Unknown_Flag,
					cmd  = cmd,
					text = tok.text,
				}
				return
			} else if f.value == .Required {
				pending = f
			} else {
				pcmd.flags[flag_name(f)] = Parsed_Flag {
					source = f,
					value  = "",
				}
			}
		case .Long_Flag:
			f: ^Flag = nil
			for &ff in cmd.flags {
				if (ff.long == tok.text) {
					f = &ff
					break
				}
			}
			if f == nil {
				ok = false
				_err = Parse_Error {
					kind = .Unknown_Flag,
					cmd  = cmd,
					text = tok.text,
				}
				return
			} else if f.value == .Required {
				pending = f
			} else {
				pcmd.flags[flag_name(f)] = Parsed_Flag {
					source = f,
					value  = "",
				}
			}
		case .Word:
			_cmd: ^Command = nil
			for c in cmd.commands {
				if c.name == tok.text {_cmd = c}
			}
			if _cmd != nil {
				append(&res, pcmd)
				pcmd = Parsed_Command {
					source = _cmd,
					flags  = make(map[string]Parsed_Flag, a),
				}
				cmd = _cmd
			} else {
				append(&res, pcmd)
				args := Parsed_Args {
					value = make([dynamic]string, a),
				}
				for tok in tokens[ndx:] {
					append(&args.value, tok.text)
				}
				append(&res, args)
				return
			}
		}
	}
	if pending != nil {
		ok = false
		_err = Parse_Error {
			kind = .Missing_Arg,
			cmd  = cmd,
			flag = pending,
		}
		return
	}
	if do_append {
		append(&res, pcmd)
	}
	return
}

/*
parse_args combines tokenize + parse in a single call.

Memory contract:
- The returned Parse_Result and everything reachable from it is allocated
  from `perm`. Free with delete_parse_result (or free_all if `perm` is an arena).
- All interim allocations (the token stream) are made from `temp` and are
  released before parse_args returns. Nothing in the result points into
  temp memory; flag values and positional args are slices of `args`.
*/
parse_args :: proc(
	spec: ^Command,
	args: []string,
	err: ^Parse_Error = nil,
	perm: runtime.Allocator = context.allocator,
	temp: runtime.Allocator = context.temp_allocator,
) -> (
	res: Parse_Result,
	ok: bool,
) {
	tokens, err_at := tokenize(args, temp)
	defer delete(tokens)
	if err_at >= 0 {
		if err != nil {
			err^ = Parse_Error{kind = .Invalid_Arg, at = err_at, text = args[err_at]}
		}
		return nil, false
	}
	return parse(spec, tokens[:], err, perm)
}
