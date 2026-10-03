//! helpers for fuzzing

const std = @import("std");

/// turns `bytes` into a corpus entry that `Smith.slice` reads back as `bytes`
/// `Smith.slice` expects a 4-byte little-endian length before the bytes
pub fn sliceSeed(comptime bytes: []const u8) []const u8 {
    return comptime &(std.mem.toBytes(std.mem.nativeToLittle(u32, bytes.len)) ++ bytes[0..].*);
}

test sliceSeed {
    var smith: std.testing.Smith = .{ .in = sliceSeed("hi") };
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("hi", buf[0..smith.slice(&buf)]);
}
