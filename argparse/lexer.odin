// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package argparse
/*
import "core:unicode/utf8"
	Command-line arg grammar

	cli := flag* command?
	command := identifier flag* command?
	flag := (short_flag | long_flag) identifier?

	That is to say. The top-level is an implicit `root` command.

	* Top-level is an implicit 'root' command
	* Every command may take zero or more flags.
	* Flags can use short names (`-f` / `-f arg`)
	* Flags can use long names (`--flag` / `--flag arg`)
	* `-f WORD` can be disambiguated by, at point of parsing, 
		* if `value: Flag_Value` for `-f` in current command says `.Optional`/`.Required`, treat as argument for flag
		* else if WORD matches a subcommand, start parsing subcommand
		* ELSE - interpret as part of positional args, pass verbatim to subcommand as positional

*/
import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

Token_Kind :: enum {
	Word,
	Short_Flag,
	Long_Flag,
	// Unix-style argument parsing uses '--' to denote end of argument parsing
	End_Of_Options,
}

Token :: struct {
	kind: Token_Kind,
	text: string,
	// The argument exactly as it appeared on the command line, for flag
	// tokens: "--long" / "-s" / (on a bundle's FIRST token) "-abc".
	// Bundle continuation tokens and non-flag tokens leave it "". Used by
	// parse to echo trailing args back verbatim once parsing gives up on
	// command/flag interpretation (`makac <script> <args...>`).
	verbatim: string,
}

Flag_Value :: enum {
	None,
	Required,
}

Flag :: struct {
	short: string,
	long:  string,
	desc:  string,
	value: Flag_Value,
}

Command :: struct {
	name:     string,
	help:     string,
	desc:     string,
	flags:    []Flag,
	commands: []^Command,
}

flag_name :: proc(f: ^Flag) -> string {
	if f.long != "" {
		return f.long
	}
	return f.short
}

tokenize :: proc(
	args: []string,
	a: runtime.Allocator = context.allocator,
) -> (
	tokens: [dynamic]Token,
	err_at: int = -1,
) {
	tokens = make([dynamic]Token, 0, len(args), allocator = a)
	defer if err_at >= 0 {
		delete(tokens)
		tokens = nil
	}

	for arg, ndx in args {
		if arg == "--" {
			append(&tokens, Token{kind = .End_Of_Options, text = "--"})
			for word in args[ndx + 1:] {
				append(&tokens, Token{kind = .Word, text = word})
			}
			return
		} else if strings.has_prefix(arg, "--") {
			flag_name := arg[2:]
			append(&tokens, Token{kind = .Long_Flag, text = flag_name, verbatim = arg})
		} else if strings.has_prefix(arg, "-") && len(arg) > 1 {
			flag_name := arg[1:]
			// Bundles ("-abc" == "-a -b -c") only cover pure letter sequences.
			// Anything else ("-n5", "-=x") cannot be a makac flag — keep the
			// whole arg as a Word so it survives as a positional argument
			// instead of failing tokenization (`makac script.lua -n5`).
			bundle := len(flag_name) > 1
			if bundle {
				for ch in flag_name {
					if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
						bundle = false
						break
					}
				}
			}
			if len(flag_name) > 1 && !bundle {
				append(&tokens, Token{kind = .Word, text = arg})
			} else if !bundle {
				append(&tokens, Token{kind = .Short_Flag, text = flag_name, verbatim = arg})
			} else {
				for ch, ch_ndx in flag_name {
					// in our case, we could have used +1 as ch is within the ASCII range.
					append(
						&tokens,
						Token {
							kind = .Short_Flag,
							text = flag_name[ch_ndx:ch_ndx + utf8.rune_size(ch)],
							// the bundle's first token carries the whole original
							// arg ("-abc"); continuations keep verbatim "" so the
							// slurp in parse emits the bundle once, intact.
							verbatim = ch_ndx == 0 ? arg : "",
						},
					)
				}
			}
		} else {
			if strings.has_prefix(arg, "-") {
				/* invalid, '-' cannot stand alone */
				err_at = ndx
				return
			}
			append(&tokens, Token{kind = .Word, text = arg})
		}
	}
	return
}
