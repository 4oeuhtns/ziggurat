//! one HTTP response, written to a writer

const std = @import("std");
const Io = std.Io;
const DateCache = @import("DateCache.zig");
const Header = @import("Request.zig").Header;
const Response = @This();

/// the statuses this server sends. Each value is its number
pub const Status = enum(u16) {
    ok = 200,
    bad_request = 400,
    not_found = 404,
    method_not_allowed = 405,
    request_timeout = 408,
    content_too_large = 413,
    request_header_fields_too_large = 431,
    internal_server_error = 500,
    not_implemented = 501,
    service_unavailable = 503,
    http_version_not_supported = 505,

    /// the words after the number, like `Not Found`
    pub fn phrase(status: Status) []const u8 {
        return switch (status) {
            .ok => "OK",
            .bad_request => "Bad Request",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .request_timeout => "Request Timeout",
            .content_too_large => "Content Too Large",
            .request_header_fields_too_large => "Request Header Fields Too Large",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .service_unavailable => "Service Unavailable",
            .http_version_not_supported => "HTTP Version Not Supported",
        };
    }

    /// the whole status line, like `HTTP/1.1 200 OK\r\n`, built at compile time
    pub fn line(status: Status) []const u8 {
        return switch (status) {
            inline else => |s| comptime std.fmt.comptimePrint("HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(s), s.phrase() }), // HTTP/1.1 version server uses
        };
    }

    /// the status that answers a request which failed with `err`, or `null` when nobody is listening
    pub fn fromError(err: anyerror) ?Status {
        return switch (err) {
            error.BadRequestLine, error.BadHeader, error.IncompleteHead, error.BadContentLength, error.AmbiguousFraming, error.BadChunkSize, error.BadChunkExtension, error.BadLineEnding, error.BadTrailer, error.IncompleteBody, error.BadHost => .bad_request,
            error.Timeout => .request_timeout,
            error.BodyTooLarge => .content_too_large,
            error.HeadTooLarge, error.TooManyHeaders => .request_header_fields_too_large,
            error.UnknownMethod, error.UnsupportedTransferEncoding => .not_implemented,
            error.UnsupportedVersion => .http_version_not_supported,
            error.HandlerFailed => .internal_server_error,
            else => null,
        };
    }
};

/// where the response goes
writer: *Io.Writer,
/// text for the `Date` header
date: *const [DateCache.len]u8,
/// whether the connection stays open afterwards
keep_alive: bool = true,
/// which status line to send
status: Status = .ok,
/// the `Content-Type` header
content_type: []const u8 = "text/plain",
/// extra headers, written as given after `Connection`
headers: []const Header = &.{},
/// for answers to `HEAD`: the head as usual, with the body's real `Content-Length`, but no body
omit_body: bool = false,
/// whether `send` has run. The server uses it to notice a handler that didn't answer
sent: bool = false,

/// writes one complete response: status line, headers, blank line, body. Doesn't flush
/// the blank line and body go in one vectored write, so a big body leaves with the head and isn't copied
pub fn send(res: *Response, body: []const u8) Io.Writer.Error!void {
    std.debug.assert(!res.sent); // one response per request
    const w = res.writer;
    try w.writeAll(res.status.line());
    try w.print("Date: {s}\r\n", .{res.date.*});
    try w.print("Content-Type: {s}\r\n", .{res.content_type});
    try w.print("Content-Length: {d}\r\n", .{body.len});
    try w.print("Connection: {s}\r\n", .{if (res.keep_alive) "keep-alive" else "close"});
    for (res.headers) |h| {
        try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    var tail = [_][]const u8{ "\r\n", if (res.omit_body) "" else body };
    try w.writeVecAll(&tail);
    res.sent = true;
}

// Tests
test "Status.line" {
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", Status.ok.line());
    try std.testing.expectEqualStrings("HTTP/1.1 404 Not Found\r\n", Status.not_found.line());
    try std.testing.expectEqualStrings("HTTP/1.1 431 Request Header Fields Too Large\r\n", Status.request_header_fields_too_large.line());

    // every status has a line, and the number in it is the enum's value
    for (std.enums.values(Status)) |status| {
        const text = status.line();
        try std.testing.expectEqual(@intFromEnum(status), try std.fmt.parseInt(u16, text[9..12], 10));
        try std.testing.expectEqualStrings(status.phrase(), text[13 .. text.len - 2]);
    }
}

test "Status.fromError" {
    const cases = [_]struct { anyerror, ?Status }{
        .{ error.BadRequestLine, .bad_request },
        .{ error.BadHeader, .bad_request },
        .{ error.IncompleteHead, .bad_request },
        .{ error.BadContentLength, .bad_request },
        .{ error.AmbiguousFraming, .bad_request },
        .{ error.BadChunkSize, .bad_request },
        .{ error.BadChunkExtension, .bad_request },
        .{ error.BadLineEnding, .bad_request },
        .{ error.BadTrailer, .bad_request },
        .{ error.Timeout, .request_timeout },
        .{ error.BodyTooLarge, .content_too_large },
        .{ error.HeadTooLarge, .request_header_fields_too_large },
        .{ error.TooManyHeaders, .request_header_fields_too_large },
        .{ error.UnknownMethod, .not_implemented },
        .{ error.UnsupportedTransferEncoding, .not_implemented },
        .{ error.UnsupportedVersion, .http_version_not_supported },
        // nobody is listening any more, so there's no answer to send
        .{ error.EndOfStream, null },
        .{ error.ConnectionResetByPeer, null },
        .{ error.WriteFailed, null },
        .{ error.Canceled, null },
        .{ error.IncompleteBody, .bad_request },
        .{ error.BadHost, .bad_request },
        .{ error.HandlerFailed, .internal_server_error },
    };
    for (cases) |case| {
        const err, const expected = case;
        errdefer std.debug.print("failed on: {t}\n", .{err});
        try std.testing.expectEqual(expected, Status.fromError(err));
    }
}

const test_date = "Sun, 06 Nov 1994 08:49:37 GMT";

test send {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    var res: Response = .{ .writer = &writer, .date = test_date };
    try res.send("Hello, World!\n");

    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\n" ++
        "Date: Sun, 06 Nov 1994 08:49:37 GMT\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 14\r\n" ++
        "Connection: keep-alive\r\n" ++
        "\r\n" ++
        "Hello, World!\n", writer.buffered());
}

test "send with every field set" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    var res: Response = .{
        .writer = &writer,
        .date = test_date,
        .keep_alive = false,
        .status = .method_not_allowed,
        .content_type = "application/json",
        .headers = &.{
            .{ .name = "Allow", .value = "GET, HEAD" },
            .{ .name = "Cache-Control", .value = "no-store" },
        },
    };
    try res.send("{}");

    try std.testing.expectEqualStrings("HTTP/1.1 405 Method Not Allowed\r\n" ++
        "Date: Sun, 06 Nov 1994 08:49:37 GMT\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 2\r\n" ++
        "Connection: close\r\n" ++
        "Allow: GET, HEAD\r\n" ++
        "Cache-Control: no-store\r\n" ++
        "\r\n" ++
        "{}", writer.buffered());
}

test "an empty body still has a length" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    var res: Response = .{ .writer = &writer, .date = test_date };
    try res.send("");

    try std.testing.expect(std.mem.find(u8, writer.buffered(), "\r\nContent-Length: 0\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), "\r\n\r\n"));
}

test "an answer to HEAD has the length but not the body" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    var res: Response = .{ .writer = &writer, .date = test_date, .omit_body = true };
    try res.send("Hello, World!\n");

    try std.testing.expect(std.mem.find(u8, writer.buffered(), "\r\nContent-Length: 14\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), "\r\n\r\n"));
}

test "send remembers that it ran" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    var res: Response = .{ .writer = &writer, .date = test_date };
    try std.testing.expect(!res.sent);
    try res.send("");
    try std.testing.expect(res.sent);
}

/// a writer that remembers how it was drained, standing in for a socket
const Recorder = struct {
    interface: Io.Writer,
    /// how many times bytes were handed to the "system"
    drains: usize = 0,
    /// how many bytes arrived in total
    bytes: usize = 0,
    /// whether `watched` was handed over as it is, without a copy through the buffer
    saw_watched: bool = false,
    watched: []const u8 = &.{},

    fn init(buffer: []u8) Recorder {
        return .{ .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const recorder: *Recorder = @alignCast(@fieldParentPtr("interface", w));
        recorder.drains += 1;
        recorder.bytes += w.end;
        w.end = 0;
        for (data) |bytes| {
            if (bytes.ptr == recorder.watched.ptr and bytes.len == recorder.watched.len) recorder.saw_watched = true;
        }
        const n = Io.Writer.countSplat(data, splat);
        recorder.bytes += n;
        return n;
    }
};

test "head and a big body leave in one write, and the body isn't copied" {
    const body: []const u8 = &@as([8192]u8, @splat('x'));

    var buf: [512]u8 = undefined;
    var recorder: Recorder = .init(&buf);
    recorder.watched = body;

    var res: Response = .{ .writer = &recorder.interface, .date = test_date };
    try res.send(body);
    try recorder.interface.flush();

    try std.testing.expectEqual(1, recorder.drains);
    try std.testing.expect(recorder.saw_watched);
    const head_len = "HTTP/1.1 200 OK\r\n".len + "Date: \r\n".len + DateCache.len +
        "Content-Type: text/plain\r\n".len + "Content-Length: 8192\r\n".len + "Connection: keep-alive\r\n".len + "\r\n".len;
    try std.testing.expectEqual(head_len + body.len, recorder.bytes);
}

test "small responses wait in the buffer" {
    var buf: [512]u8 = undefined;
    var recorder: Recorder = .init(&buf);

    var res: Response = .{ .writer = &recorder.interface, .date = test_date };
    try res.send("one");
    res.sent = false; // pretend the next request came in
    try res.send("two");
    try std.testing.expectEqual(0, recorder.drains); // nothing sent yet: pipelined answers can leave together

    try recorder.interface.flush();
    try std.testing.expectEqual(1, recorder.drains);
}
