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

/// Slow but obviously correct implementation of `findHeadEnd` for fuzzing
fn findHeadEndSlow(bytes: []const u8) ?usize {
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 1) {
        if (std.mem.eql(u8, bytes[i .. i + 4], "\r\n\r\n")) return i + 4;
    }
    return null;
}

fn fuzzFindHeadEnd(_: void, smith: *std.testing.Smith) !void {
    var buf: [256]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];
    try std.testing.expectEqual(findHeadEndSlow(input), findHeadEnd(input));
}

test "fuzz findHeadEnd against slow version" {
    try std.testing.fuzz({}, fuzzFindHeadEnd, .{
        .corpus = &.{
            "GET / HTTP/1.1\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: a\r\n\r\nhello",
        },
    });
}
