// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// version.zig — the VM-facing view of makac's version constants.
//
// The single source of truth for the values is `src/version.zig`
// (also used by main.zig's `--version`); this module re-exports it so the vm/
// tree mirrors the reference layout without duplicating the constants.

const std = @import("std");
const testing = std.testing;
const src = @import("../version.zig");

pub const version = src.version;
pub const major = src.major;
pub const minor = src.minor;

test "vm version re-exports the single source of truth" {
    try testing.expectEqual(src.major, major);
    try testing.expectEqual(src.minor, minor);
    try testing.expectEqualStrings(src.version, version);
}
