//! HTTP/1.1

const std = @import("std");

/// Returns index just after HTTP head (`\r\n\r\n`), or `null`
pub fn findHeadEnd(bytes: []const u8) ?usize {
    const i = std.mem.find(u8, bytes, "\r\n\r\n") orelse return null;
    return i + 4;
}

test findHeadEnd {
    try std.testing.expectEqual(18, findHeadEnd("GET / HTTP/1.1\r\n\r\n"));
    try std.testing.expectEqual(null, findHeadEnd("GET / HTTP/1.1\r\n"));
    try std.testing.expectEqual(null, findHeadEnd(""));
}
