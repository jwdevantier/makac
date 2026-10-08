// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// json.zig — makac.json.dumps/loads and the shared Lua↔JSON converters.
//
// The converters live here (not inside the binding) so the qmp binding can
// reuse them verbatim: qmp:send marshals command arguments with exactly these
// rules, and qmp reply decoding pushes values with exactly these rules:
//
//   * tables are JSON objects unless every key is an integer in 1..n (then
//     arrays); an EMPTY table encodes as {}; mixed-key tables raise with the
//     value's path in the message;
//   * decoding keeps integers as integers;
//   * every Lua string uses explicit lengths — NUL and UTF-8 round-trip;
//   * BOTH directions are depth-bounded (MAX_JSON_DEPTH): a cyclic table or a
//     pathologically deep document raises a Lua error instead of growing the
//     C stack until the process dies.

const std = @import("std");
const lua = @import("../lua.zig");
const reg = @import("register.zig");

const c_alloc = std.heap.c_allocator;

/// Recursion bound for Lua↔JSON conversion, BOTH directions. Real QMP and
/// workflow data never nests anywhere near this deep; a value that does is
/// pathological or CYCLIC — either way it must raise, not crash.
pub const MAX_JSON_DEPTH: usize = 64;

/// Internal parse bound (safety only): the public decode guard fires at
/// MAX_JSON_DEPTH during the push, so `loads` of a 64-deep document still
/// works while a 65-deep one raises "nesting exceeds". This larger bound just
/// keeps the recursive parser from overflowing the C stack on absurd input.
const MAX_PARSE_DEPTH: usize = 2000;

pub const Error = error{
    OutOfMemory,
    DepthExceeded,
    StackExhausted,
    MixedKeys,
    BadKeyType,
    Unencodable,
};

pub const ParseError = error{ Malformed, OutOfMemory };

/// A JSON value tree. Object entry order is preserved (cheap and
/// deterministic on the wire); lookup is not needed.
pub const Value = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    array: []Value,
    object: []Entry,
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

/// Self-contained diagnostic message. The buffer lives on the caller's stack,
/// so it survives freeing the arena that built the value's path strings — the
/// wrappers deinit the arena, then raise with `msg`.
pub const Diag = struct {
    buf: [1024]u8 = undefined,
    msg: []const u8 = "",

    pub fn set(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        self.msg = std.fmt.bufPrint(&self.buf, fmt, args) catch self.buf[0..0];
    }
};

fn typeNameAt(L: *lua.State, idx: c_int) []const u8 {
    const p = lua.typeName(L, idx);
    return std.mem.sliceTo(@as([*]const u8, @ptrCast(p)), 0);
}

// ------------------------------------------------- Lua -> Value ------------

/// Convert the Lua value at `idx` to a Value tree (owned by `arena`).
/// `path` locates the value in error messages (e.g. "commands[2].arguments"),
/// `prefix` names the caller-facing API (e.g. "makac.json" / "makac.qmp"),
/// `depth` is the recursion level (callers pass 0).
pub fn luaToJson(
    L: *lua.State,
    idx: c_int,
    path: []const u8,
    prefix: []const u8,
    depth: usize,
    arena: std.mem.Allocator,
    diag: *Diag,
) Error!Value {
    if (depth >= MAX_JSON_DEPTH) {
        diag.set("{s}: {s}: nesting exceeds {d} levels (cyclic table?)", .{ prefix, path, MAX_JSON_DEPTH });
        return error.DepthExceeded;
    }
    if (lua.c.lua_checkstack(L, 4) == 0) {
        diag.set("{s}: {s}: Lua stack exhausted while encoding", .{ prefix, path });
        return error.StackExhausted;
    }
    const abs = lua.absindex(L, idx);
    switch (lua.typeOf(L, abs)) {
        lua.TNIL => return .nil,
        lua.TBOOLEAN => return .{ .boolean = lua.toBoolean(L, abs) },
        lua.TNUMBER => {
            if (lua.c.lua_isinteger(L, abs) != 0) {
                return .{ .integer = lua.toInteger(L, abs) };
            }
            const f = lua.toNumber(L, abs);
            if (std.math.isNan(f) or std.math.isInf(f)) {
                diag.set("{s}: {s}: number cannot be encoded as JSON", .{ prefix, path });
                return error.Unencodable;
            }
            return .{ .float = f };
        },
        lua.TSTRING => {
            const s = lua.toLString(L, abs) orelse return error.Unencodable;
            return .{ .string = arena.dupe(u8, s) catch return error.OutOfMemory };
        },
        lua.TTABLE => return tableToJson(L, abs, path, prefix, depth, arena, diag),
        else => {
            diag.set("{s}: {s}: {s} values cannot be encoded as JSON", .{ prefix, path, typeNameAt(L, abs) });
            return error.Unencodable;
        },
    }
}

fn tableToJson(
    L: *lua.State,
    abs: c_int,
    path: []const u8,
    prefix: []const u8,
    depth: usize,
    arena: std.mem.Allocator,
    diag: *Diag,
) Error!Value {
    const n = lua.rawLen(L, abs);
    var count: usize = 0;
    var is_arr = n > 0;
    lua.pushNil(L);
    while (lua.next(L, abs) != 0) {
        count += 1;
        if (lua.typeOf(L, -2) != lua.TNUMBER or lua.c.lua_isinteger(L, -2) == 0) is_arr = false;
        lua.pop(L, 1);
    }
    if (is_arr and count == n) {
        const arr = arena.alloc(Value, n) catch return error.OutOfMemory;
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            _ = lua.rawGetI(L, abs, @intCast(i));
            const child = std.fmt.allocPrint(arena, "{s}[{d}]", .{ path, i }) catch return error.OutOfMemory;
            arr[i - 1] = try luaToJson(L, -1, child, prefix, depth + 1, arena, diag);
            lua.pop(L, 1);
        }
        return .{ .array = arr };
    }
    if (is_arr) {
        diag.set("{s}: {s} mixes array and non-array keys; cannot encode as JSON", .{ prefix, path });
        return error.MixedKeys;
    }
    var entries: std.ArrayList(Entry) = .empty;
    lua.pushNil(L);
    while (lua.next(L, abs) != 0) {
        // key at -2, value at -1
        if (lua.typeOf(L, -2) != lua.TSTRING) {
            diag.set("{s}: {s}: JSON object keys must be strings, got {s}", .{ prefix, path, typeNameAt(L, -2) });
            lua.pop(L, 1);
            return error.BadKeyType;
        }
        const key = lua.toLString(L, -2) orelse {
            lua.pop(L, 1);
            return error.BadKeyType;
        };
        const key_dup = arena.dupe(u8, key) catch return error.OutOfMemory;
        const child = std.fmt.allocPrint(arena, "{s}.{s}", .{ path, key }) catch return error.OutOfMemory;
        const val = try luaToJson(L, -1, child, prefix, depth + 1, arena, diag);
        entries.append(arena, .{ .key = key_dup, .value = val }) catch return error.OutOfMemory;
        lua.pop(L, 1);
    }
    return .{ .object = entries.items };
}

// ------------------------------------------------- Value -> Lua ------------

/// Push a Value onto the Lua stack as plain Lua values (objects/arrays become
/// tables; integers stay integers). `depth` is the recursion level (callers
/// pass 0; values nested past MAX_JSON_DEPTH raise).
pub fn pushJson(L: *lua.State, v: Value, depth: usize, diag: *Diag) Error!void {
    if (depth >= MAX_JSON_DEPTH) {
        diag.set("JSON value nesting exceeds {d} levels", .{MAX_JSON_DEPTH});
        return error.DepthExceeded;
    }
    if (lua.c.lua_checkstack(L, 4) == 0) {
        diag.set("Lua stack exhausted while decoding JSON", .{});
        return error.StackExhausted;
    }
    switch (v) {
        .nil => lua.pushNil(L),
        .boolean => |b| lua.pushBoolean(L, b),
        .integer => |i| lua.pushInteger(L, i),
        .float => |f| lua.pushNumber(L, f),
        .string => |s| lua.pushLString(L, s),
        .array => |a| {
            lua.createTable(L, @intCast(a.len), 0);
            for (a, 0..) |elem, i| {
                try pushJson(L, elem, depth + 1, diag);
                lua.rawSetI(L, -2, @intCast(i + 1));
            }
        },
        .object => |o| {
            lua.createTable(L, 0, @intCast(o.len));
            for (o) |e| {
                // lua_settable/lua_rawset: key just below the top, value on
                // top (`t[k] = v`).
                lua.pushLString(L, e.key);
                try pushJson(L, e.value, depth + 1, diag);
                lua.c.lua_rawset(L, -3);
            }
        },
    }
}

// ------------------------------------------------------- parser ------------

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,
    depth: usize = 0,

    fn parseDocument(self: *Parser) ParseError!Value {
        const v = try self.parseValue();
        self.skipWs();
        if (self.pos != self.src.len) return error.Malformed;
        return v;
    }

    fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => return,
            }
        }
    }

    fn expect(self: *Parser, lit: []const u8) ParseError!void {
        if (self.pos + lit.len > self.src.len) return error.Malformed;
        if (!std.mem.eql(u8, self.src[self.pos .. self.pos + lit.len], lit)) return error.Malformed;
        self.pos += lit.len;
    }

    fn parseValue(self: *Parser) ParseError!Value {
        if (self.depth > MAX_PARSE_DEPTH) return error.Malformed;
        self.skipWs();
        if (self.pos >= self.src.len) return error.Malformed;
        return switch (self.src[self.pos]) {
            'n' => blk: {
                try self.expect("null");
                break :blk .nil;
            },
            't' => blk: {
                try self.expect("true");
                break :blk .{ .boolean = true };
            },
            'f' => blk: {
                try self.expect("false");
                break :blk .{ .boolean = false };
            },
            '"' => .{ .string = try self.parseString() },
            '[' => self.parseArray(),
            '{' => self.parseObject(),
            '-', '0'...'9' => self.parseNumber(),
            else => error.Malformed,
        };
    }

    fn parseArray(self: *Parser) ParseError!Value {
        self.pos += 1; // '['
        self.depth += 1;
        defer self.depth -= 1;
        var items: std.ArrayList(Value) = .empty;
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == ']') {
            self.pos += 1;
            return .{ .array = &.{} };
        }
        while (true) {
            const v = try self.parseValue();
            items.append(self.arena, v) catch return error.OutOfMemory;
            self.skipWs();
            if (self.pos >= self.src.len) return error.Malformed;
            switch (self.src[self.pos]) {
                ',' => {
                    self.pos += 1;
                    self.skipWs();
                    continue;
                },
                ']' => {
                    self.pos += 1;
                    break;
                },
                else => return error.Malformed,
            }
        }
        return .{ .array = items.items };
    }

    fn parseObject(self: *Parser) ParseError!Value {
        self.pos += 1; // '{'
        self.depth += 1;
        defer self.depth -= 1;
        var entries: std.ArrayList(Entry) = .empty;
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == '}') {
            self.pos += 1;
            return .{ .object = &.{} };
        }
        while (true) {
            self.skipWs();
            if (self.pos >= self.src.len or self.src[self.pos] != '"') return error.Malformed;
            const key = try self.parseString();
            self.skipWs();
            if (self.pos >= self.src.len or self.src[self.pos] != ':') return error.Malformed;
            self.pos += 1;
            const val = try self.parseValue();
            entries.append(self.arena, .{ .key = key, .value = val }) catch return error.OutOfMemory;
            self.skipWs();
            if (self.pos >= self.src.len) return error.Malformed;
            switch (self.src[self.pos]) {
                ',' => {
                    self.pos += 1;
                    continue;
                },
                '}' => {
                    self.pos += 1;
                    break;
                },
                else => return error.Malformed,
            }
        }
        return .{ .object = entries.items };
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        self.pos += 1; // opening '"'
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.pos >= self.src.len) return error.Malformed;
            const ch = self.src[self.pos];
            if (ch == '"') {
                self.pos += 1;
                break;
            }
            if (ch == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) return error.Malformed;
                const esc = self.src[self.pos];
                self.pos += 1;
                switch (esc) {
                    '"' => try appendByte(&out, self.arena, '"'),
                    '\\' => try appendByte(&out, self.arena, '\\'),
                    '/' => try appendByte(&out, self.arena, '/'),
                    'b' => try appendByte(&out, self.arena, 0x08),
                    'f' => try appendByte(&out, self.arena, 0x0c),
                    'n' => try appendByte(&out, self.arena, '\n'),
                    'r' => try appendByte(&out, self.arena, '\r'),
                    't' => try appendByte(&out, self.arena, '\t'),
                    'u' => {
                        const cp = try self.parseHex4();
                        if (cp >= 0xD800 and cp <= 0xDBFF and
                            self.pos + 1 < self.src.len and
                            self.src[self.pos] == '\\' and self.src[self.pos + 1] == 'u')
                        {
                            self.pos += 2;
                            const lo = try self.parseHex4();
                            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                const combined: u21 = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                try appendCodepoint(&out, self.arena, combined);
                            } else {
                                try appendCodepoint(&out, self.arena, cp);
                                try appendCodepoint(&out, self.arena, lo);
                            }
                        } else {
                            try appendCodepoint(&out, self.arena, cp);
                        }
                    },
                    else => return error.Malformed,
                }
                continue;
            }
            if (ch < 0x20) return error.Malformed; // raw control chars are illegal
            try appendByte(&out, self.arena, ch);
            self.pos += 1;
        }
        return out.items;
    }

    fn parseHex4(self: *Parser) ParseError!u21 {
        if (self.pos + 4 > self.src.len) return error.Malformed;
        var v: u21 = 0;
        for (self.src[self.pos .. self.pos + 4]) |h| {
            const d: u21 = switch (h) {
                '0'...'9' => h - '0',
                'a'...'f' => h - 'a' + 10,
                'A'...'F' => h - 'A' + 10,
                else => return error.Malformed,
            };
            v = v * 16 + d;
        }
        self.pos += 4;
        return v;
    }

    fn parseNumber(self: *Parser) ParseError!Value {
        const start = self.pos;
        if (self.src[self.pos] == '-') self.pos += 1;
        if (self.pos >= self.src.len) return error.Malformed;
        if (self.src[self.pos] == '0') {
            self.pos += 1;
        } else if (self.src[self.pos] >= '1' and self.src[self.pos] <= '9') {
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
        } else return error.Malformed;

        var is_float = false;
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            is_float = true;
            self.pos += 1;
            if (self.pos >= self.src.len or !isDigit(self.src[self.pos])) return error.Malformed;
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
        }
        if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) self.pos += 1;
            if (self.pos >= self.src.len or !isDigit(self.src[self.pos])) return error.Malformed;
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
        }

        const text = self.src[start..self.pos];
        if (!is_float) {
            if (std.fmt.parseInt(i64, text, 10)) |i| return .{ .integer = i } else |_| {}
        }
        const f = std.fmt.parseFloat(f64, text) catch return error.Malformed;
        return .{ .float = f };
    }
};

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn appendByte(out: *std.ArrayList(u8), arena: std.mem.Allocator, b: u8) ParseError!void {
    out.append(arena, b) catch return error.OutOfMemory;
}

fn appendCodepoint(out: *std.ArrayList(u8), arena: std.mem.Allocator, cp: u21) ParseError!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        // Lone surrogate: emit WTF-8 (3 bytes) so the value is deterministic.
        buf[0] = @intCast(0xE0 | (cp >> 12));
        buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (cp & 0x3F));
        out.appendSlice(arena, buf[0..3]) catch return error.OutOfMemory;
        return;
    };
    out.appendSlice(arena, buf[0..n]) catch return error.OutOfMemory;
}

/// Parse a whole JSON document. Raises at the call site on malformed input.
pub fn parseJson(src: []const u8, arena: std.mem.Allocator) ParseError!Value {
    var p = Parser{ .src = src, .arena = arena };
    return p.parseDocument();
}

// ---------------------------------------------------- serializer -----------

/// Serialize a Value tree to JSON (owned by `arena`).
pub fn writeJson(arena: std.mem.Allocator, v: Value) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try writeValue(&out, v, arena);
    return out.items;
}

fn writeValue(out: *std.ArrayList(u8), v: Value, arena: std.mem.Allocator) error{OutOfMemory}!void {
    switch (v) {
        .nil => try out.appendSlice(arena, "null"),
        .boolean => |b| try out.appendSlice(arena, if (b) "true" else "false"),
        .integer => |i| {
            var b: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "{d}", .{i}) catch unreachable;
            try out.appendSlice(arena, s);
        },
        .float => |f| {
            var b: [64]u8 = undefined;
            try out.appendSlice(arena, formatFloat(&b, f));
        },
        .string => |s| try writeString(out, s, arena),
        .array => |a| {
            try out.append(arena, '[');
            for (a, 0..) |e, i| {
                if (i != 0) try out.append(arena, ',');
                try writeValue(out, e, arena);
            }
            try out.append(arena, ']');
        },
        .object => |o| {
            try out.append(arena, '{');
            for (o, 0..) |e, i| {
                if (i != 0) try out.append(arena, ',');
                try writeString(out, e.key, arena);
                try out.append(arena, ':');
                try writeValue(out, e.value, arena);
            }
            try out.append(arena, '}');
        },
    }
}

/// Shortest round-tripping decimal for a finite float; an integral float keeps
/// its subtype on the wire by gaining a ".0" (so `loads(dumps(1e3))` is a
/// float, matching the reference's `%f` rendering).
fn formatFloat(buf: []u8, f: f64) []const u8 {
    const s = std.fmt.bufPrint(buf, "{d}", .{f}) catch return "0.0";
    if (std.mem.indexOfAny(u8, s, ".eE") != null) return s;
    if (s.len + 2 > buf.len) return s;
    buf[s.len] = '.';
    buf[s.len + 1] = '0';
    return buf[0 .. s.len + 2];
}

fn writeString(out: *std.ArrayList(u8), s: []const u8, arena: std.mem.Allocator) error{OutOfMemory}!void {
    try out.append(arena, '"');
    const hex = "0123456789abcdef";
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            0x08 => try out.appendSlice(arena, "\\b"),
            0x0c => try out.appendSlice(arena, "\\f"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            else => {
                if (ch < 0x20) {
                    const esc = [6]u8{ '\\', 'u', '0', '0', hex[ch >> 4], hex[ch & 0x0F] };
                    try out.appendSlice(arena, &esc);
                } else {
                    try out.append(arena, ch);
                }
            },
        }
    }
    try out.append(arena, '"');
}

// -------------------------------------------------------- binding ----------

pub fn registerJson(L: *lua.State) void {
    reg.pushSubmodule(L, "json");
    defer lua.pop(L, 1);
    lua.pushCFunction(L, jsonDumps);
    lua.setField(L, -2, "dumps");
    lua.pushCFunction(L, jsonLoads);
    lua.setField(L, -2, "loads");
}

/// makac.json.dumps(value) -> string — raises on unencodable values.
fn jsonDumps(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    lua.checkAny(L, 1);
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    const arena = arena_state.allocator();
    var diag = Diag{};
    const v = luaToJson(L, 1, "value", "makac.json", 0, arena, &diag) catch {
        arena_state.deinit();
        lua.raiseLString(L, if (diag.msg.len != 0) diag.msg else "makac.json: dumps: out of memory");
    };
    const data = writeJson(arena, v) catch {
        arena_state.deinit();
        lua.raiseLString(L, "makac.json: dumps: failed to encode value as JSON");
    };
    lua.pushLString(L, data);
    arena_state.deinit();
    return 1;
}

/// makac.json.loads(string) -> value — raises on malformed JSON. Strict: a
/// number argument must raise (no string coercion).
fn jsonLoads(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    lua.checkType(L, 1, lua.TSTRING);
    const src = lua.toLString(L, 1) orelse unreachable;
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    const arena = arena_state.allocator();
    const v = parseJson(src, arena) catch {
        arena_state.deinit();
        raiseMalformed(L, src);
    };
    var diag = Diag{};
    pushJson(L, v, 0, &diag) catch {
        arena_state.deinit();
        lua.raiseLString(L, if (diag.msg.len != 0) diag.msg else "makac.json: loads: cannot build value");
    };
    arena_state.deinit();
    return 1;
}

fn raiseMalformed(L: *lua.State, src: []const u8) noreturn {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "makac.json: loads: malformed JSON: {s}", .{src}) catch
        "makac.json: loads: malformed JSON";
    lua.raiseLString(L, msg);
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

fn newTestVM() !*@import("../vm.zig").VM {
    return @import("../vm.zig").VM.new(testing.allocator, testing.io, .{});
}

test "json submodule shape" {
    const v = try newTestVM();
    defer v.deinit();
    try v.runString(
        \\assert(type(makac.json) == "table")
        \\assert(type(makac.json.dumps) == "function")
        \\assert(type(makac.json.loads) == "function")
    , "@json_test");
}

test "json roundtrip: nested containers, integer/float subtypes" {
    const v = try newTestVM();
    defer v.deinit();
    try v.runString(
        \\local orig = {
        \\  name = "vm1", cpus = 4, mem_mib = 4096, pi = 3.5,
        \\  enabled = true, disabled = false, nothing = nil,
        \\  nested = { drives = { "nvme0", "sda" }, flags = { true, false } },
        \\  list = { 1, "two", 3.25, { deep = "x" } },
        \\}
        \\local back = makac.json.loads(makac.json.dumps(orig))
        \\assert(back.name == "vm1")
        \\assert(back.cpus == 4 and math.type(back.cpus) == "integer")
        \\assert(back.pi == 3.5 and math.type(back.pi) == "float")
        \\assert(back.enabled == true and back.disabled == false)
        \\assert(back.nested.drives[1] == "nvme0" and back.nested.drives[2] == "sda")
        \\assert(back.list[2] == "two" and back.list[3] == 3.25)
        \\assert(back.list[4].deep == "x")
        \\assert(back.nothing == nil)
    , "@json_test");
}

test "json empty table is object and array/object key shapes" {
    const v = try newTestVM();
    defer v.deinit();
    try v.runString(
        \\assert(makac.json.dumps({}) == "{}")
        \\assert(makac.json.dumps({ empty = {} }) == '{"empty":{}}')
        \\assert(makac.json.dumps({1,2,3}) == "[1,2,3]")
        \\assert(makac.json.dumps({ "a", { "b", "c" } }) == '["a",["b","c"]]')
        \\assert(makac.json.dumps({ x = 1 }) == '{"x":1}')
        \\local e = makac.json.loads("{}")
        \\assert(type(e) == "table" and next(e) == nil)
        \\assert(type(makac.json.loads("[]")) == "table" and #makac.json.loads("[]") == 0)
    , "@json_test");
}

test "json integer preservation" {
    const v = try newTestVM();
    defer v.deinit();
    try v.runString(
        \\local v = makac.json.loads('{"a": 1, "b": -42, "big": 4611686018427387903, "f": 2.5, "e": 1e3}')
        \\assert(math.type(v.a) == "integer" and v.a == 1)
        \\assert(math.type(v.b) == "integer" and v.b == -42)
        \\assert(math.type(v.big) == "integer" and v.big == 4611686018427387903)
        \\assert(math.type(v.f) == "float" and v.f == 2.5)
        \\assert(math.type(v.e) == "float" and v.e == 1000.0)
        \\assert(makac.json.dumps(7) == "7")
        \\assert(makac.json.loads(makac.json.dumps(2.5)) == 2.5)
        \\assert(makac.json.loads(makac.json.dumps(1e3)) == 1000.0)
    , "@json_test");
}

test "json mixed/holey tables and bad key types raise with a path" {
    const v = try newTestVM();
    defer v.deinit();
    try v.runString(
        \\local ok1, e1 = pcall(makac.json.dumps, { 1, nil, 3 })
        \\assert(not ok1 and tostring(e1):find("mixes array and non-array", 1, true))
        \\local ok2 = pcall(makac.json.dumps, { [2] = "a", [3] = "b" })
        \\assert(not ok2, "non-1..n integer keys must raise")
        \\local ok3, e3 = pcall(makac.json.dumps, { 1, 2, extra = true })
        \\assert(not ok3 and (tostring(e3):find("number") or tostring(e3):find("mixes")))
    , "@json_test");
}

test "json raises on unencodable values with the value's path" {
    const v = try newTestVM();
    defer v.deinit();
    try v.runString(
        \\local ok1, e1 = pcall(makac.json.dumps, function() end)
        \\assert(not ok1 and tostring(e1):find("function"))
        \\local ok2, e2 = pcall(makac.json.dumps, { cb = function() end })
        \\assert(not ok2 and tostring(e2):find("value%.cb"))
        \\local ok3, e3 = pcall(makac.json.dumps, { list = { 1, print } })
        \\assert(not ok3 and tostring(e3):find("value%.list%[2%]"))
    , "@json_test");
}

test "json loads rejects garbage, coerces nothing" {
    const v = try newTestVM();
    defer v.deinit();
    try v.runString(
        \\for _, bad in ipairs({ "{ not json", "[1, 2,", "", "{x: 1}", "42abc", "tru", '"unterminated' }) do
        \\  local ok, err = pcall(makac.json.loads, bad)
        \\  assert(not ok, "must raise: " .. bad)
        \\  assert(tostring(err):find("malformed"), tostring(err))
        \\end
        \\assert(not pcall(makac.json.loads, 42))
        \\assert(makac.json.loads("null") == nil)
        \\assert(makac.json.loads("true") == true)
        \\assert(makac.json.loads('"hi"') == "hi")
    , "@json_test");
}

test "json depth and cycle guards, both directions" {
    const v = try newTestVM();
    defer v.deinit();
    try v.runString(
        \\-- cyclic table: must raise naming the limit, not crash
        \\local cyc = {}; cyc.self = cyc
        \\local ok1, e1 = pcall(makac.json.dumps, cyc)
        \\assert(not ok1 and tostring(e1):find("nesting exceeds", 1, true), tostring(e1))
        \\local deep = {}
        \\for _ = 1, 100 do deep = { next = deep } end
        \\local ok2, e2 = pcall(makac.json.dumps, deep)
        \\assert(not ok2 and tostring(e2):find("nesting exceeds", 1, true), tostring(e2))
        \\-- shared subtrees (a DAG) are not a cycle
        \\local shared = { x = 1 }
        \\local rt = makac.json.loads(makac.json.dumps({ a = shared, b = shared }))
        \\assert(rt.a.x == 1 and rt.b.x == 1)
        \\-- decode: 64 levels decode, 65 raise
        \\assert(pcall(makac.json.loads, ("["):rep(64) .. ("]"):rep(64)))
        \\local ok3, e3 = pcall(makac.json.loads, ("["):rep(65) .. ("]"):rep(65))
        \\assert(not ok3 and tostring(e3):find("nesting exceeds", 1, true), tostring(e3))
        \\local ok4, e4 = pcall(makac.json.loads, ("["):rep(80) .. ("]"):rep(80))
        \\assert(not ok4 and tostring(e4):find("nesting exceeds", 1, true), tostring(e4))
    , "@json_test");
}

test "json NUL and UTF-8 round-trip (NUL-safe by construction)" {
    const v = try newTestVM();
    defer v.deinit();
    try v.runString(
        \\local back = makac.json.loads(makac.json.dumps({ s = "a\0b\0c", u = "héllo → wörld\nline2\ttab" }))
        \\assert(#back.s == 5 and back.s:byte(1) == 97 and back.s:byte(2) == 0 and back.s:byte(4) == 0)
        \\assert(back.u == "héllo → wörld\nline2\ttab")
        \\-- \u0000 and a surrogate pair decode correctly
        \\assert(makac.json.loads('"a\\u0000b"') == "a\0b")
        \\assert(makac.json.loads('"\\uD83D\\uDE00"') == "\240\159\152\128")
    , "@json_test");
}
