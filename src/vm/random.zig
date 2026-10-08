// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// random.zig — `makac.random_hex`, the one flat misc primitive that does not
// fit under a submodule.

const std = @import("std");
const lua = @import("../lua.zig");
const reg = @import("register.zig");
const linux = std.os.linux;

const c_alloc = std.heap.c_allocator;

fn oom(L: *lua.State) noreturn {
    lua.raiseLString(L, "makac: out of memory");
}

pub fn registerRandom(L: *lua.State) void {
    reg.register(L, "random_hex", randomHex);
}

/// Fill `buf` from getrandom(2), resuming on EINTR (the kernel may also
/// return short reads before the pool is seeded).
fn fillRandom(L: *lua.State, buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.getrandom(buf.ptr + off, buf.len - off, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            else => lua.raise(L, "makac: random_hex: getrandom failed"),
        }
    }
}

/// makac.random_hex(n) -> string — exactly n lowercase hex chars.
fn randomHex(L_opt: ?*lua.State) callconv(.c) c_int {
    const L = L_opt.?;
    const n = lua.checkInteger(L, 1);
    if (n <= 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "makac: random_hex: n must be positive (got {d})",
            .{n},
        ) catch "makac: random_hex: n must be positive";
        lua.raiseLString(L, msg);
    }

    const want: usize = @intCast(n);
    const nbytes = (want + 1) / 2;
    const bytes = c_alloc.alloc(u8, nbytes) catch oom(L);
    defer c_alloc.free(bytes);
    fillRandom(L, bytes);

    const out = c_alloc.alloc(u8, want) catch oom(L);
    defer c_alloc.free(out);
    const hex = "0123456789abcdef";
    for (0..want) |i| {
        const b = bytes[i / 2];
        out[i] = hex[if (i % 2 == 0) b >> 4 else b & 0x0f];
    }
    lua.pushLString(L, out);
    return 1;
}

// --------------------------------------------------------------- tests -----

const testing = std.testing;

test "random_hex: length, charset, uniqueness, odd n, validation" {
    const VM = @import("../vm.zig").VM;
    const vm_instance = try VM.new(testing.allocator, testing.io, .{});
    defer vm_instance.deinit();
    try vm_instance.runString(
        \\local a = makac.random_hex(16)
        \\assert(#a == 16, "length honored")
        \\assert(a:match("^[0-9a-f]+$"), "lowercase hex charset")
        \\assert(a ~= makac.random_hex(16), "two draws differ")
        \\local odd = makac.random_hex(7)
        \\assert(#odd == 7 and odd:match("^[0-9a-f]+$"), "odd n works")
        \\assert(not pcall(makac.random_hex, 0), "zero raises")
        \\assert(not pcall(makac.random_hex, -3), "negative raises")
    , "@random_test");
}
