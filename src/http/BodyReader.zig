//! the body of one request, read from the connection, ending exactly where the body ends

const std = @import("std");
const Io = std.Io;
const Request = @import("Request.zig");
const ChunkedDecoder = @import("ChunkedDecoder.zig");
const BodyReader = @This();

/// the connection the body comes from
in: *Io.Reader,
/// how far through the body we are
state: State,
/// how many more bytes of `in` this body may use
allowance: u64,
/// what the handler reads through
interface: Io.Reader,
/// why a read failed, when it was the body's fault
err: ?Error,

/// why a body was refused
pub const Error = ChunkedDecoder.DecoderError || error{ BodyTooLarge, IncompleteBody };

const State = union(enum) {
    /// a `Content-Length` body with this many bytes still to come
    length: u64,
    /// a chunked body in progress
    chunked: ChunkedDecoder,
    /// the body is over
    done,
};

/// a reader for one body: `in` is the connection, `framing` comes from the parsed request
pub fn init(in: *Io.Reader, framing: Request.Body, max_len: u64, buffer: []u8) BodyReader {
    return .{
        .in = in,
        .state = switch (framing) {
            .length => |n| .{ .length = n },
            .chunked => .{ .chunked = .{} },
            .none => .done,
        },
        .allowance = max_len,
        .interface = .{
            .vtable = &.{ .stream = streamImpl },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
        .err = null,
    };
}

fn streamImpl(io_r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const b: *BodyReader = @alignCast(@fieldParentPtr("interface", io_r));
    switch (b.state) {
        .done => return error.EndOfStream,
        .length => |left| {
            if (left == 0) {
                b.state = .done;
                return error.EndOfStream;
            }
            if (left > b.allowance) return b.fail(error.BodyTooLarge);
            const min_lim = limit.min(.limited64(left));
            const n = b.in.stream(w, min_lim) catch |err| switch (err) {
                error.EndOfStream => return b.fail(error.IncompleteBody),
                else => |e| return e,
            };
            b.state = .{ .length = left - n };
            b.allowance -= n;
            return n;
        },
        .chunked => |*decoder| {
            while (!decoder.isDone()) {
                const min_lim = limit.min(.limited64(b.allowance + 1));

                const step = decoder.feed((min_lim.slice(b.in.peekGreedy(1) catch |err| switch (err) {
                    error.EndOfStream => return b.fail(error.IncompleteBody),
                    else => |e| return e,
                }))) catch |err| return b.fail(err);

                if (step.consumed > b.allowance) return b.fail(error.BodyTooLarge);
                b.allowance -= step.consumed;
                try w.writeAll(step.data);
                b.in.toss(step.consumed);

                if (step.data.len > 0) return step.data.len;
            }
            b.state = .done;
            return error.EndOfStream;
        },
    }
}

/// stores why the body failed, and returns the error a reader is allowed to return
fn fail(b: *BodyReader, err: Error) Io.Reader.StreamError {
    b.err = err;
    return error.ReadFailed;
}

// Tests
/// reads everything `body` gives into `out`, returns the bytes read
fn readAll(body: *BodyReader, out: []u8) ![]u8 {
    var writer: Io.Writer = .fixed(out);
    _ = try body.interface.streamRemaining(&writer);
    return writer.buffered();
}

test "no body" {
    var in: Io.Reader = .fixed("GET /next HTTP/1.1\r\n\r\n");
    var body: BodyReader = .init(&in, .none, 100, &.{});

    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try readAll(&body, &out));
    try std.testing.expectEqualStrings("GET /next HTTP/1.1\r\n\r\n", in.buffered()); // untouched
}

test "a body with a length stops at that length" {
    var in: Io.Reader = .fixed("helloGET /next HTTP/1.1\r\n\r\n");
    var body: BodyReader = .init(&in, .{ .length = 5 }, 100, &.{});

    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try readAll(&body, &out));
    try std.testing.expectEqualStrings("GET /next HTTP/1.1\r\n\r\n", in.buffered());
}

test "a chunked body comes out without its chunking" {
    var in: Io.Reader = .fixed("5\r\nhello\r\n6;x=y\r\n world\r\n0\r\nTrailer: 1\r\n\r\nGET /next HTTP/1.1\r\n\r\n");
    var body: BodyReader = .init(&in, .chunked, 100, &.{});

    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello world", try readAll(&body, &out));
    try std.testing.expectEqualStrings("GET /next HTTP/1.1\r\n\r\n", in.buffered());
}

test "works through a buffer of its own" {
    var in: Io.Reader = .fixed("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\nNEXT");
    var buf: [4]u8 = undefined;
    var body: BodyReader = .init(&in, .chunked, 100, &buf);

    try std.testing.expectEqualStrings("hell", try body.interface.take(4));
    try std.testing.expectEqual('o', try body.interface.takeByte());
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings(" world", try readAll(&body, &out));
    try std.testing.expectEqualStrings("NEXT", in.buffered());
}

test "the part nobody read can be thrown away" {
    const cases = [_]struct { []const u8, Request.Body }{
        .{ "hello worldNEXT", .{ .length = 11 } },
        .{ "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\nNEXT", .chunked },
    };
    for (cases) |case| {
        const input, const framing = case;
        var in: Io.Reader = .fixed(input);
        var body: BodyReader = .init(&in, framing, 100, &.{});

        var two: [2]u8 = undefined;
        try body.interface.readSliceAll(&two);
        try std.testing.expectEqualStrings("he", &two);

        try std.testing.expectEqual(9, try body.interface.discardRemaining());
        try std.testing.expectEqualStrings("NEXT", in.buffered());
    }
}

test "a body cut short is an error, not a short body" {
    const cases = [_]struct { []const u8, Request.Body }{
        .{ "hel", .{ .length = 5 } },
        .{ "5\r\nhel", .chunked },
        .{ "5\r\nhello\r\n", .chunked }, // no last chunk
        .{ "5\r\nhello\r\n0\r\n", .chunked }, // no final blank line
    };
    for (cases) |case| {
        const input, const framing = case;
        errdefer std.debug.print("failed on: \"{f}\"\n", .{std.zig.fmtString(input)});
        var in: Io.Reader = .fixed(input);
        var body: BodyReader = .init(&in, framing, 100, &.{});

        var out: [64]u8 = undefined;
        try std.testing.expectError(error.ReadFailed, readAll(&body, &out));
        try std.testing.expect(body.err.? == error.IncompleteBody);
    }
}

test "a body over the limit is refused" {
    const cases = [_]struct { []const u8, Request.Body, u64 }{
        .{ "hello world", .{ .length = 11 }, 10 },
        .{ "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", .chunked, 25 }, // one byte short: the chunking counts too
        .{ "1;" ++ "x" ** 100 ++ "\r\na\r\n0\r\n\r\n", .chunked, 50 }, // a tiny body hiding in a huge extension
    };
    for (cases) |case| {
        const input, const framing, const max_len = case;
        errdefer std.debug.print("failed on: \"{f}\"\n", .{std.zig.fmtString(input)});
        var in: Io.Reader = .fixed(input);
        var body: BodyReader = .init(&in, framing, max_len, &.{});

        var out: [64]u8 = undefined;
        try std.testing.expectError(error.ReadFailed, readAll(&body, &out));
        try std.testing.expect(body.err.? == error.BodyTooLarge);
    }
}

test "a body exactly at the limit is fine" {
    const cases = [_]struct { []const u8, Request.Body, u64 }{
        .{ "hello world", .{ .length = 11 }, 11 },
        .{ "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", .chunked, 26 },
    };
    for (cases) |case| {
        const input, const framing, const max_len = case;
        var in: Io.Reader = .fixed(input);
        var body: BodyReader = .init(&in, framing, max_len, &.{});

        var out: [64]u8 = undefined;
        try std.testing.expectEqualStrings("hello world", try readAll(&body, &out));
    }
}

test "bad chunking is reported with the decoder's own error" {
    var in: Io.Reader = .fixed("zz\r\nhello\r\n0\r\n\r\n");
    var body: BodyReader = .init(&in, .chunked, 100, &.{});

    var out: [64]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, readAll(&body, &out));
    try std.testing.expect(body.err.? == error.BadChunkSize);
}
