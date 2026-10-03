//! parses HTTP/1.1 request head according to RFC 9112 spec
//! zero copy, returns slices pointing to bytes

const std = @import("std");
const sliceSeed = @import("../fuzz.zig").sliceSeed;
const Request = @This();

method: Method,
target: []const u8,
version: Version,
headers: []const Header,

pub const Method = enum { GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, TRACE, PATCH };
pub const Version = enum { @"HTTP/1.0", @"HTTP/1.1" };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// error types
pub const ParseError = error{
    /// request line isn't `method ' ' target ' ' version'
    BadRequestLine,
    /// unknown method
    UnknownMethod,
    /// version isn't HTTP/1.0 or HTTP/1.1
    UnsupportedVersion,
    /// header line is incorrect
    BadHeader,
    /// too many headers, don't fit in `header_buf`
    TooManyHeaders,
    /// `head` doesn't end with blank line
    IncompleteHead,
};

/// Returns index just after HTTP head (`\r\n\r\n`), or `null`
pub fn findHeadEnd(bytes: []const u8) ?usize {
    const i = std.mem.find(u8, bytes, "\r\n\r\n") orelse return null;
    return i + 4;
}

/// parses request head, up to blank line found by `findHeadEnd`
/// results point to `head` and `header_buf`
pub fn parse(head: []const u8, header_buf: []Header) ParseError!Request {
    if (!std.mem.endsWith(u8, head, "\r\n\r\n")) return error.IncompleteHead;
    var lines = std.mem.splitSequence(u8, head[0 .. head.len - 4], "\r\n");

    // request line must be `method ' ' target ' ' version`, split by spaces
    var parts = std.mem.splitScalar(u8, lines.first(), ' ');
    const method_text = parts.first();
    const target = parts.next() orelse return error.BadRequestLine;
    const version_text = parts.next() orelse return error.BadRequestLine;
    if (parts.next() != null) return error.BadRequestLine;

    if (!isToken(method_text)) return error.BadRequestLine;
    const method = std.meta.stringToEnum(Method, method_text) orelse return error.UnknownMethod;

    if (target.len == 0) return error.BadRequestLine;
    for (target) |c| {
        switch (c) {
            '!'...'~' => {}, // visible ASCII range
            else => return error.BadRequestLine,
        }
    }

    const version = std.meta.stringToEnum(Version, version_text) orelse {
        if (std.mem.startsWith(u8, version_text, "HTTP/")) return error.UnsupportedVersion;
        return error.BadRequestLine;
    };

    // header lines
    var i: usize = 0;
    while (lines.next()) |line| {
        if (i == header_buf.len) return error.TooManyHeaders;
        header_buf[i] = try parseHeader(line);
        i += 1;
    }

    return .{
        .method = method,
        .target = target,
        .version = version,
        .headers = header_buf[0..i],
    };
}

/// returns value of first header with `name` or `null`
pub fn header(request: Request, name: []const u8) ?[]const u8 {
    for (request.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// `name: whitespace value whitespace`
fn parseHeader(line: []const u8) ParseError!Header {
    const name, const rest = std.mem.cutScalar(u8, line, ':') orelse return error.BadHeader;
    if (!isToken(name)) return error.BadHeader;

    const value = std.mem.trim(u8, rest, " \t");
    for (value) |c| {
        switch (c) {
            '\t', ' '...'~', 0x80...0xff => {},
            else => return error.BadHeader, // control bytes
        }
    }
    return .{ .name = name, .value = value };
}

// a 'token' is one ore more of these characters only (RFC 9110 section 5.6.2)
fn isToken(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9' => {},
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
            else => return false,
        }
    }
    return true;
}

// Tests

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
            sliceSeed("GET / HTTP/1.1\r\n\r\n"),
            sliceSeed("GET / HTTP/1.1\r\nHost: a\r\n\r\nhello"),
        },
    });
}

test "parse a simple GET" {
    const head = "GET /hello?x=1 HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\n\r\n";
    var header_buf: [8]Header = undefined;
    const request = try parse(head, &header_buf);

    try std.testing.expectEqual(.GET, request.method);
    try std.testing.expectEqualStrings("/hello?x=1", request.target);
    try std.testing.expectEqual(.@"HTTP/1.1", request.version);
    try std.testing.expectEqual(2, request.headers.len);
    try std.testing.expectEqualStrings("Accept", request.headers[1].name);
    try std.testing.expectEqualStrings("*/*", request.headers[1].value);
}

test "parsed values point into the input" {
    const head: []const u8 = "GET /a HTTP/1.1\r\nHost: x\r\n\r\n";
    var header_buf: [8]Header = undefined;
    const request = try parse(head, &header_buf);

    try std.testing.expectEqual(head.ptr + 4, request.target.ptr);
    try std.testing.expectEqual(head.ptr + 23, request.headers[0].value.ptr);
}

test header {
    const head = "GET / HTTP/1.1\r\nContent-Type: text/plain\r\n\r\n";
    var header_buf: [8]Header = undefined;
    const request = try parse(head, &header_buf);

    try std.testing.expectEqualStrings("text/plain", request.header("content-type").?);
    try std.testing.expectEqual(null, request.header("host"));
}

test "whitespace around header values is trimmed" {
    const head = "GET / HTTP/1.1\r\nX-Pad: \t spaced out \t\r\n\r\n";
    var header_buf: [8]Header = undefined;
    const request = try parse(head, &header_buf);

    try std.testing.expectEqualStrings("spaced out", request.header("x-pad").?);
}

test "rejects malformed heads" {
    const cases = [_]struct { []const u8, ParseError }{
        .{ "get / HTTP/1.1\r\n\r\n", error.UnknownMethod }, // methods are case-sensitive
        .{ "BREW / HTTP/1.1\r\n\r\n", error.UnknownMethod },
        .{ "GET  / HTTP/1.1\r\n\r\n", error.BadRequestLine }, // two spaces
        .{ "GET /a b HTTP/1.1\r\n\r\n", error.BadRequestLine }, // space in target
        .{ "GET /\r\n\r\n", error.BadRequestLine }, // no version
        .{ "GET / http/1.1\r\n\r\n", error.BadRequestLine },
        .{ "GET / HTTP/2.0\r\n\r\n", error.UnsupportedVersion },
        .{ "GET / HTTP/1.1\r\nHost : x\r\n\r\n", error.BadHeader }, // space before colon
        .{ "GET / HTTP/1.1\r\nHost: x\r\n folded\r\n\r\n", error.BadHeader }, // obsolete line folding
        .{ "GET / HTTP/1.1\r\nNoColon\r\n\r\n", error.BadHeader },
        .{ "GET / HTTP/1.1\r\n: no-name\r\n\r\n", error.BadHeader },
        .{ "GET / HTTP/1.1\r\nX: a\rb\r\n\r\n", error.BadHeader }, // stray CR
        .{ "GET / HTTP/1.1\r\nHost: x\r\n", error.IncompleteHead },
    };
    for (cases) |case| {
        const input, const expected = case;
        errdefer std.debug.print("failed on: \"{f}\"\n", .{std.zig.fmtString(input)});
        var header_buf: [8]Header = undefined;
        try std.testing.expectError(expected, parse(input, &header_buf));
    }
}

test "rejects more headers than fit" {
    var header_buf: [1]Header = undefined;
    const head = "GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\n\r\n";
    try std.testing.expectError(error.TooManyHeaders, parse(head, &header_buf));
}

fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    // fuzzer picks the head's lines, always add the blank line
    // most inputs get past the `IncompleteHead`
    var buf: [512]u8 = undefined;
    const len = smith.slice(buf[0 .. buf.len - 4]);
    buf[len..][0..4].* = "\r\n\r\n".*;
    const input = buf[0 .. len + 4];
    var header_buf: [16]Header = undefined;
    const request = parse(input, &header_buf) catch return; // rejecting is fine, crashing isn't

    // accepted must point into the input and hide no CR or LF
    try expectClean(input, request.target);
    for (request.headers) |h| {
        try expectClean(input, h.name);
        try expectClean(input, h.value);
    }
}

fn expectClean(input: []const u8, part: []const u8) !void {
    const start = @intFromPtr(input.ptr);
    const part_start = @intFromPtr(part.ptr);
    try std.testing.expect(part_start >= start and part_start + part.len <= start + input.len);
    try std.testing.expect(std.mem.findAny(u8, part, "\r\n") == null);
}

test "fuzz parse" {
    try std.testing.fuzz({}, fuzzParse, .{
        .corpus = &.{
            sliceSeed("GET / HTTP/1.1\r\nHost: a"),
            sliceSeed("POST /x?y=1 HTTP/1.0\r\nContent-Length: 5\r\nX: \t v "),
        },
    });
}
