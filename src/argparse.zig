// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// argparse.zig — the makac command-line grammar.
//
// Grammar:
//
//   cli     := flag* command?
//   command := identifier flag* command?
//   flag    := (short_flag | long_flag) identifier?
//
// The top-level is an implicit `root` command.
//   * Every command may take zero or more flags.
//   * Flags can use short names (`-f` / `-f arg`).
//   * Flags can use long names (`--flag` / `--flag arg`).
//   * `-f WORD` is disambiguated at parse time:
//       - if `-f`'s value is Required, WORD is its argument;
//       - else if WORD names a subcommand, start that subcommand;
//       - else WORD and everything after it are positional, echoed verbatim.

const std = @import("std");

pub const TokenKind = enum {
    word,
    short_flag,
    long_flag,
    /// Unix-style `--` denotes the end of option parsing.
    end_of_options,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    /// For flag tokens: the argument exactly as it appeared on the command
    /// line ("--long" / "-s" / the bundle's FIRST token "-abc"). Bundle
    /// continuations and non-flag tokens leave it "". Used to echo trailing
    /// arguments back verbatim once parsing gives up.
    verbatim: []const u8 = "",

    pub fn eql(a: Token, b: Token) bool {
        return a.kind == b.kind and
            std.mem.eql(u8, a.text, b.text) and
            std.mem.eql(u8, a.verbatim, b.verbatim);
    }
};

pub const FlagValue = enum { none, required };

pub const Flag = struct {
    short: []const u8 = "",
    long: []const u8 = "",
    desc: []const u8 = "",
    value: FlagValue = .none,
};

pub const Command = struct {
    name: []const u8,
    help: []const u8 = "",
    desc: []const u8 = "",
    flags: []const Flag = &.{},
    commands: []const *const Command = &.{},
};

/// The canonical name of a flag: the long form when present, else the short.
pub fn flagName(f: *const Flag) []const u8 {
    return if (f.long.len > 0) f.long else f.short;
}

// --------------------------------------------------------------- lexer -----

pub const Tokenized = struct {
    tokens: []Token,
    err_at: ?usize,
};

/// Split `args` into tokens. On a lexical error (`err_at != null`) `tokens` is
/// empty. The token texts borrow from `args`.
pub fn tokenize(allocator: std.mem.Allocator, args: []const []const u8) error{OutOfMemory}!Tokenized {
    var list: std.ArrayList(Token) = .empty;
    errdefer list.deinit(allocator);

    for (args, 0..) |arg, ndx| {
        if (std.mem.eql(u8, arg, "--")) {
            try list.append(allocator, .{ .kind = .end_of_options, .text = "--" });
            for (args[ndx + 1 ..]) |word| {
                try list.append(allocator, .{ .kind = .word, .text = word });
            }
            return .{ .tokens = try list.toOwnedSlice(allocator), .err_at = null };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try list.append(allocator, .{
                .kind = .long_flag,
                .text = arg[2..],
                .verbatim = arg,
            });
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            const flag_name = arg[1..];
            // Bundles ("-abc" == "-a -b -c") only cover pure letter sequences.
            // Anything else ("-n5", "-=x") cannot be a makac flag — keep the
            // whole arg as a Word so it survives as a positional argument.
            var bundle = flag_name.len > 1;
            if (bundle) {
                for (flag_name) |ch| {
                    if (!std.ascii.isAlphabetic(ch)) {
                        bundle = false;
                        break;
                    }
                }
            }
            if (flag_name.len > 1 and !bundle) {
                try list.append(allocator, .{ .kind = .word, .text = arg });
            } else if (!bundle) {
                try list.append(allocator, .{
                    .kind = .short_flag,
                    .text = flag_name,
                    .verbatim = arg,
                });
            } else {
                for (flag_name, 0..) |_, ch_ndx| {
                    // Only ASCII letters reach here, so one byte per component.
                    try list.append(allocator, .{
                        .kind = .short_flag,
                        .text = flag_name[ch_ndx .. ch_ndx + 1],
                        .verbatim = if (ch_ndx == 0) arg else "",
                    });
                }
            }
        } else {
            if (std.mem.startsWith(u8, arg, "-")) {
                // A bare '-' cannot stand alone.
                list.deinit(allocator);
                return .{ .tokens = &.{}, .err_at = ndx };
            }
            try list.append(allocator, .{ .kind = .word, .text = arg });
        }
    }
    return .{ .tokens = try list.toOwnedSlice(allocator), .err_at = null };
}

// -------------------------------------------------------------- parser -----

pub const ParsedFlag = struct {
    source: *const Flag,
    value: []const u8,
};

const FlagsMap = std.StringHashMapUnmanaged(ParsedFlag);

pub const ParsedCommand = struct {
    source: *const Command,
    flags: FlagsMap,
};

pub const ParsedArgs = struct {
    value: [][]const u8,
};

pub const Parsed = union(enum) {
    command: ParsedCommand,
    args: ParsedArgs,
};

pub const ParseResult = []Parsed;

pub const ParseErrorKind = enum { none, invalid_arg, unknown_flag, missing_arg };

pub const ParseError = struct {
    kind: ParseErrorKind = .none,
    cmd: ?*const Command = null,
    flag: ?*const Flag = null,
    /// Offending positional (invalid_arg) or flag name (unknown_flag).
    text: []const u8 = "",
    /// Index into args for invalid_arg; -1 otherwise.
    at: isize = -1,
};

pub const Failure = error{ ParseFailed, OutOfMemory };

/// Last Parsed_Command in the result, or null. The result alternates
/// command/args blocks, and the last command is what the caller almost always
/// wants.
pub fn lastCommand(pr: []const Parsed) ?ParsedCommand {
    var found: ?ParsedCommand = null;
    for (pr) |e| switch (e) {
        .command => |c| found = c,
        .args => {},
    };
    return found;
}

/// The single Parsed_Args block, if present. The parser emits at most one.
pub fn findArgs(pr: []const Parsed) ?ParsedArgs {
    for (pr) |e| switch (e) {
        .command => {},
        .args => |a| return a,
    };
    return null;
}

/// Free everything reachable from a parse result.
pub fn deleteParseResult(allocator: std.mem.Allocator, result: []Parsed) void {
    for (result) |e| switch (e) {
        .command => |c| {
            var flags = c.flags;
            flags.deinit(allocator);
        },
        .args => |a| allocator.free(a.value),
    };
    allocator.free(result);
}

fn deinitPartial(allocator: std.mem.Allocator, res: *std.ArrayList(Parsed)) void {
    for (res.items) |e| switch (e) {
        .command => |c| {
            var flags = c.flags;
            flags.deinit(allocator);
        },
        .args => |a| allocator.free(a.value),
    };
    res.deinit(allocator);
}

fn findShort(cmd: *const Command, text: []const u8) ?*const Flag {
    for (cmd.flags) |*f| {
        if (std.mem.eql(u8, f.short, text)) return f;
    }
    return null;
}

fn findLong(cmd: *const Command, text: []const u8) ?*const Flag {
    for (cmd.flags) |*f| {
        if (std.mem.eql(u8, f.long, text)) return f;
    }
    return null;
}

fn findSubcommand(cmd: *const Command, name: []const u8) ?*const Command {
    for (cmd.commands) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

fn collectVerbatim(
    allocator: std.mem.Allocator,
    toks: []const Token,
) error{OutOfMemory}![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    for (toks) |t| {
        switch (t.kind) {
            .end_of_options => try list.append(allocator, "--"),
            .short_flag, .long_flag => {
                // Bundle continuation tokens have empty verbatim; the bundle's
                // first token already carried it in full.
                if (t.verbatim.len > 0) try list.append(allocator, t.verbatim);
            },
            else => try list.append(allocator, t.text),
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn setErr(out: ?*ParseError, e: ParseError) void {
    if (out) |o| o.* = e;
}

pub fn parse(
    allocator: std.mem.Allocator,
    spec: *const Command,
    tokens: []const Token,
    err_out: ?*ParseError,
) Failure!ParseResult {
    var res: std.ArrayList(Parsed) = .empty;
    errdefer deinitPartial(allocator, &res);

    var pending: ?*const Flag = null;
    var cmd: *const Command = spec;
    var pcmd = ParsedCommand{ .source = spec, .flags = .empty };
    var pcmd_in_res = false;
    errdefer if (!pcmd_in_res) pcmd.flags.deinit(allocator);

    var ndx: usize = 0;
    while (ndx < tokens.len) : (ndx += 1) {
        const tok = tokens[ndx];

        if (pending) |p| {
            if (tok.kind != .word) {
                setErr(err_out, .{ .kind = .missing_arg, .cmd = cmd, .flag = p });
                return error.ParseFailed;
            }
            try pcmd.flags.put(allocator, flagName(p), .{ .source = p, .value = tok.text });
            pending = null;
            continue;
        }

        switch (tok.kind) {
            .end_of_options => {
                try res.append(allocator, .{ .command = pcmd });
                pcmd_in_res = true;
                const value = try collectVerbatim(allocator, tokens[ndx + 1 ..]);
                try res.append(allocator, .{ .args = .{ .value = value } });
                return try res.toOwnedSlice(allocator);
            },
            .short_flag => {
                const f = findShort(cmd, tok.text) orelse {
                    setErr(err_out, .{ .kind = .unknown_flag, .cmd = cmd, .text = tok.text });
                    return error.ParseFailed;
                };
                if (f.value == .required) {
                    pending = f;
                } else {
                    try pcmd.flags.put(allocator, flagName(f), .{ .source = f, .value = "" });
                }
            },
            .long_flag => {
                const f = findLong(cmd, tok.text) orelse {
                    setErr(err_out, .{ .kind = .unknown_flag, .cmd = cmd, .text = tok.text });
                    return error.ParseFailed;
                };
                if (f.value == .required) {
                    pending = f;
                } else {
                    try pcmd.flags.put(allocator, flagName(f), .{ .source = f, .value = "" });
                }
            },
            .word => {
                if (findSubcommand(cmd, tok.text)) |sub| {
                    try res.append(allocator, .{ .command = pcmd });
                    pcmd_in_res = true;
                    cmd = sub;
                    pcmd = .{ .source = sub, .flags = .empty };
                    pcmd_in_res = false;
                } else {
                    try res.append(allocator, .{ .command = pcmd });
                    pcmd_in_res = true;
                    // Parsing stops interpreting at the first word that is no
                    // subcommand: it and EVERYTHING after it is positional and
                    // echoed with its original spelling (dashes intact).
                    const value = try collectVerbatim(allocator, tokens[ndx..]);
                    try res.append(allocator, .{ .args = .{ .value = value } });
                    return try res.toOwnedSlice(allocator);
                }
            },
        }
    }

    if (pending) |p| {
        setErr(err_out, .{ .kind = .missing_arg, .cmd = cmd, .flag = p });
        return error.ParseFailed;
    }
    try res.append(allocator, .{ .command = pcmd });
    pcmd_in_res = true;
    return try res.toOwnedSlice(allocator);
}

/// tokenize + parse in one call. Interim token memory is released before this
/// returns; the result borrows from `args`.
pub fn parseArgs(
    allocator: std.mem.Allocator,
    spec: *const Command,
    args: []const []const u8,
    err_out: ?*ParseError,
) Failure!ParseResult {
    const t = try tokenize(allocator, args);
    defer allocator.free(t.tokens);
    if (t.err_at) |at| {
        setErr(err_out, .{
            .kind = .invalid_arg,
            .at = @intCast(at),
            .text = args[at],
        });
        return error.ParseFailed;
    }
    return parse(allocator, spec, t.tokens, err_out);
}

// --------------------------------------------------------------- tests -----

const TokenizeCase = struct {
    name: []const u8,
    args: []const []const u8,
    expected: []const Token,
    want_err_at: ?usize = null,
};

const tokenize_cases = [_]TokenizeCase{
    .{ .name = "empty", .args = &.{}, .expected = &.{} },
    .{ .name = "single word", .args = &.{"hello"}, .expected = &.{
        .{ .kind = .word, .text = "hello" },
    } },
    .{ .name = "two words", .args = &.{ "hello", "world" }, .expected = &.{
        .{ .kind = .word, .text = "hello" },
        .{ .kind = .word, .text = "world" },
    } },
    .{ .name = "long flag", .args = &.{"--flag"}, .expected = &.{
        .{ .kind = .long_flag, .text = "flag", .verbatim = "--flag" },
    } },
    .{ .name = "short flag", .args = &.{"-f"}, .expected = &.{
        .{ .kind = .short_flag, .text = "f", .verbatim = "-f" },
    } },
    .{ .name = "bundled short", .args = &.{"-abc"}, .expected = &.{
        .{ .kind = .short_flag, .text = "a", .verbatim = "-abc" },
        .{ .kind = .short_flag, .text = "b" },
        .{ .kind = .short_flag, .text = "c" },
    } },
    .{ .name = "end of opts", .args = &.{"--"}, .expected = &.{
        .{ .kind = .end_of_options, .text = "--" },
    } },
    .{ .name = "bare dash", .args = &.{"-"}, .expected = &.{}, .want_err_at = 0 },
    .{ .name = "bundle with non-letter stays a word", .args = &.{"-n5"}, .expected = &.{
        .{ .kind = .word, .text = "-n5" },
    } },
    .{ .name = "nested command", .args = &.{ "-v", "--conf", "/tmp/conf", "build-img", "--force", "myimg" }, .expected = &.{
        .{ .kind = .short_flag, .text = "v", .verbatim = "-v" },
        .{ .kind = .long_flag, .text = "conf", .verbatim = "--conf" },
        .{ .kind = .word, .text = "/tmp/conf" },
        .{ .kind = .word, .text = "build-img" },
        .{ .kind = .long_flag, .text = "force", .verbatim = "--force" },
        .{ .kind = .word, .text = "myimg" },
    } },
};

test "tokenize cases" {
    const alloc = std.testing.allocator;
    for (tokenize_cases) |c| {
        const got = try tokenize(alloc, c.args);
        defer alloc.free(got.tokens);

        if (c.want_err_at) |want| {
            try std.testing.expectEqual(@as(?usize, want), got.err_at);
            try std.testing.expectEqual(@as(usize, 0), got.tokens.len);
            continue;
        }
        try std.testing.expectEqual(@as(?usize, null), got.err_at);
        try std.testing.expectEqual(c.expected.len, got.tokens.len);
        for (c.expected, got.tokens) |want, actual| {
            if (!want.eql(actual)) {
                std.debug.print("[{s}] token mismatch\n  want: {any}\n  got:  {any}\n", .{
                    c.name, want, actual,
                });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// --- shared command spec ---

var child_spec = Command{
    .name = "child",
    .flags = &.{
        .{ .long = "force", .value = .none },
        .{ .short = "o", .long = "output", .value = .required },
    },
};

var root_spec = Command{
    .name = "root",
    .flags = &.{
        .{ .short = "v", .long = "verbose", .value = .none },
        .{ .short = "f", .long = "conf", .value = .required },
    },
    .commands = &.{&child_spec},
};

const ExpectedFlag = struct { name: []const u8, value: []const u8 };

const ParseCase = struct {
    name: []const u8,
    args: []const []const u8,
    ok: bool,
    err_kind: ParseErrorKind = .none,
    err_flag: []const u8 = "",
    err_text: []const u8 = "",
    cmds: []const []const u8 = &.{},
    flags: []const ExpectedFlag = &.{},
    has_pos: bool = false,
    pos: []const []const u8 = &.{},
};

const parse_cases = [_]ParseCase{
    .{ .name = "empty", .args = &.{}, .ok = true, .cmds = &.{"root"} },
    .{ .name = "boolean long flag", .args = &.{"--verbose"}, .ok = true, .cmds = &.{"root"}, .flags = &.{
        .{ .name = "verbose", .value = "" },
    } },
    .{ .name = "boolean short flag", .args = &.{"-v"}, .ok = true, .cmds = &.{"root"}, .flags = &.{
        .{ .name = "verbose", .value = "" },
    } },
    .{ .name = "required short flag with value", .args = &.{ "-f", "val.txt" }, .ok = true, .cmds = &.{"root"}, .flags = &.{
        .{ .name = "conf", .value = "val.txt" },
    } },
    .{ .name = "required long flag with value", .args = &.{ "--conf", "val.txt" }, .ok = true, .cmds = &.{"root"}, .flags = &.{
        .{ .name = "conf", .value = "val.txt" },
    } },
    .{ .name = "subcommand with flag and positional", .args = &.{ "child", "--force", "sub-pos.txt" }, .ok = true, .cmds = &.{ "root", "child" }, .flags = &.{
        .{ .name = "force", .value = "" },
    }, .has_pos = true, .pos = &.{"sub-pos.txt"} },
    .{ .name = "subcommand required flag with value", .args = &.{ "child", "-o", "out.bin" }, .ok = true, .cmds = &.{ "root", "child" }, .flags = &.{
        .{ .name = "output", .value = "out.bin" },
    } },
    .{ .name = "positional args only", .args = &.{ "foo", "bar" }, .ok = true, .cmds = &.{"root"}, .has_pos = true, .pos = &.{ "foo", "bar" } },
    .{ .name = "end of options marker", .args = &.{ "--", "pos.txt", "--not-a-flag" }, .ok = true, .cmds = &.{"root"}, .has_pos = true, .pos = &.{ "pos.txt", "--not-a-flag" } },
    .{ .name = "positional args verbatim", .args = &.{ "script.lua", "--flag", "-x", "-abc", "val", "--", "-q" }, .ok = true, .cmds = &.{"root"}, .has_pos = true, .pos = &.{ "script.lua", "--flag", "-x", "-abc", "val", "--", "-q" } },
    .{ .name = "unknown flag", .args = &.{"--bogus"}, .ok = false, .err_kind = .unknown_flag, .err_text = "bogus" },
    .{ .name = "unknown short flag", .args = &.{"-z"}, .ok = false, .err_kind = .unknown_flag, .err_text = "z" },
    .{ .name = "missing arg at end of input", .args = &.{"-f"}, .ok = false, .err_kind = .missing_arg, .err_flag = "conf" },
    .{ .name = "missing arg followed by another flag", .args = &.{ "--conf", "--verbose" }, .ok = false, .err_kind = .missing_arg, .err_flag = "conf" },
};

fn expectStrs(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try std.testing.expectEqualStrings(e, a);
}

fn expectParse(c: ParseCase, spec: *const Command) !void {
    const alloc = std.testing.allocator;

    const tk = try tokenize(alloc, c.args);
    defer alloc.free(tk.tokens);
    try std.testing.expect(tk.err_at == null);

    var pe: ParseError = .{};
    const pr = parse(alloc, spec, tk.tokens, &pe) catch |e| {
        if (e != error.ParseFailed) return e;
        try std.testing.expect(!c.ok);
        try std.testing.expectEqual(c.err_kind, pe.kind);
        if (c.err_flag.len > 0) {
            try std.testing.expect(pe.flag != null);
            try std.testing.expectEqualStrings(c.err_flag, flagName(pe.flag.?));
        } else {
            try std.testing.expect(pe.flag == null);
        }
        if (c.err_text.len > 0) try std.testing.expectEqualStrings(c.err_text, pe.text);
        return;
    };
    defer deleteParseResult(alloc, pr);
    try std.testing.expect(c.ok);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    for (pr) |e| switch (e) {
        .command => |pc| try names.append(alloc, pc.source.name),
        .args => {},
    };
    try expectStrs(c.cmds, names.items);

    if (c.flags.len > 0) {
        const lc = lastCommand(pr) orelse return error.TestUnexpectedResult;
        for (c.flags) |ef| {
            const pf = lc.flags.get(ef.name) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(ef.value, pf.value);
        }
        try std.testing.expectEqual(@as(usize, c.flags.len), lc.flags.count());
    }

    const ap = findArgs(pr);
    if (c.has_pos) {
        const a = ap orelse return error.TestUnexpectedResult;
        try expectStrs(c.pos, a.value);
    } else {
        try std.testing.expect(ap == null);
    }
}

test "parse cases" {
    for (parse_cases) |c| {
        expectParse(c, &root_spec) catch |e| {
            std.debug.print("[{s}] parse case failed: {s}\n", .{ c.name, @errorName(e) });
            return e;
        };
    }
}

test "parse_args happy path" {
    const alloc = std.testing.allocator;
    var pe: ParseError = .{};
    const pr = try parseArgs(alloc, &root_spec, &.{ "-v", "-f", "conf.txt", "child", "--force", "pos.txt" }, &pe);
    defer deleteParseResult(alloc, pr);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    for (pr) |e| switch (e) {
        .command => |pc| try names.append(alloc, pc.source.name),
        .args => {},
    };
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("root", names.items[0]);
    try std.testing.expectEqualStrings("child", names.items[1]);

    const root_cmd = pr[0].command;
    try std.testing.expectEqualStrings("", root_cmd.flags.get("verbose").?.value);
    try std.testing.expectEqualStrings("conf.txt", root_cmd.flags.get("conf").?.value);

    const child_cmd = pr[1].command;
    try std.testing.expectEqualStrings("", child_cmd.flags.get("force").?.value);

    const args = findArgs(pr).?;
    try std.testing.expectEqual(@as(usize, 1), args.value.len);
    try std.testing.expectEqualStrings("pos.txt", args.value[0]);
}

test "parse_args invalid arg" {
    const alloc = std.testing.allocator;
    var pe: ParseError = .{};
    const r = parseArgs(alloc, &root_spec, &.{ "-v", "-" }, &pe);
    try std.testing.expectError(error.ParseFailed, r);
    try std.testing.expectEqual(ParseErrorKind.invalid_arg, pe.kind);
    try std.testing.expectEqual(@as(isize, 1), pe.at);
    try std.testing.expectEqualStrings("-", pe.text);
}

test "parse_args frees temp token memory" {
    const alloc = std.testing.allocator;
    var pe: ParseError = .{};
    const pr = try parseArgs(
        alloc,
        &root_spec,
        &.{ "-v", "-f", "conf.txt", "child", "-o", "out.bin", "pos" },
        &pe,
    );
    deleteParseResult(alloc, pr);
}
