//! decodes a chunked body (RFC 9112 section 7.1), a piece at a time

const std = @import("std");
const chars = @import("chars.zig");
const sliceSeed = @import("../fuzz.zig").sliceSeed;

const ChunkedDecoder = @This();

state: State = .size_start,
remaining: u64 = 0, // size of current chunk, then how many still to come

/// where the decoder is in the body, comments show what each state reads
const State = enum {
    /// first hex digit of a chunk size: `5`
    size_start,
    /// more hex digits, then `;` or `\r`: `5\r`
    size,
    /// a chunk extension, skipped: `;name=value`
    ext,
    /// `\n` ending the size line
    size_lf,
    /// the chunk's data: `hello`
    data,
    /// `\r` after the data
    data_cr,
    /// `\n` after the data
    data_lf,
    /// after the last chunk: a trailer's first byte, or the `\r` of the final empty line
    trailer_start,
    /// rest of a trailer's name, then `:`
    trailer_name,
    /// a trailer's value, then `\r`
    trailer_value,
    /// `\n` ending a trailer line
    trailer_lf,
    /// `\n` of the final empty line
    end_lf,
    /// body is over, anything after belongs to the next request
    done,
};

pub const DecoderError = error{
    /// chunk size missing, not hex, or too big
    BadChunkSize,
    /// chunk extension has a control byte
    BadChunkExtension,
    /// a line doesn't end with `\r\n`, or chunk data is longer than its size
    BadLineEnding,
    /// trailer line isn't `name: value`
    BadTrailer,
};

/// what one call to `feed` did
pub const Step = struct {
    /// bytes of `input` used up, the caller drops these
    consumed: usize,
    /// body bytes found, points into `input`, can be empty
    data: []const u8,
};

pub fn feed(d: *ChunkedDecoder, input: []const u8) DecoderError!Step {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        switch (d.state) {
            .size_start => {
                d.remaining = std.fmt.charToDigit(c, 16) catch return error.BadChunkSize;
                d.state = .size;
            },
            .size => switch (c) {
                ';' => d.state = .ext,
                '\r' => d.state = .size_lf,
                else => {
                    const digit = std.fmt.charToDigit(c, 16) catch return error.BadChunkSize;
                    d.remaining = std.math.mul(u64, d.remaining, 16) catch return error.BadChunkSize;
                    d.remaining = std.math.add(u64, d.remaining, digit) catch return error.BadChunkSize;
                },
            },
            .ext => switch (c) {
                '\r' => d.state = .size_lf,
                else => if (!chars.isValueChar(c)) return error.BadChunkExtension,
            },
            .size_lf => {
                if (c != '\n') return error.BadLineEnding;
                d.state = if (d.remaining == 0) .trailer_start else .data;
            },
            .data => {
                // hand back as much data without copying
                const n: usize = @intCast(@min(d.remaining, input.len - i));
                d.remaining -= n;
                if (d.remaining == 0) d.state = .data_cr;
                return .{ .consumed = i + n, .data = input[i..][0..n] };
            },
            .data_cr => {
                if (c != '\r') return error.BadLineEnding;
                d.state = .data_lf;
            },
            .data_lf => {
                if (c != '\n') return error.BadLineEnding;
                d.state = .size_start;
            },
            .trailer_start => {
                if (c == '\r') {
                    d.state = .end_lf;
                } else if (chars.isTokenChar(c)) {
                    d.state = .trailer_name;
                } else return error.BadTrailer;
            },
            .trailer_name => {
                if (c == ':') {
                    d.state = .trailer_value;
                } else if (!chars.isTokenChar(c)) return error.BadTrailer;
            },
            .trailer_value => {
                if (c == '\r') {
                    d.state = .trailer_lf;
                } else if (!chars.isValueChar(c)) return error.BadTrailer;
            },
            .trailer_lf => {
                if (c != '\n') return error.BadLineEnding;
                d.state = .trailer_start;
            },
            .end_lf => {
                if (c != '\n') return error.BadLineEnding;
                d.state = .done;
            },
            .done => return .{ .consumed = i, .data = &.{} },
        }
    }
    return .{ .consumed = input.len, .data = &.{} };
}

/// determine whether body has been read
pub fn isDone(d: ChunkedDecoder) bool {
    return d.state == .done;
}

// Tests
/// feeds `input` at most `piece_len` bytes at a time, like a network would
/// writes the body to `out`, returns how many bytes of `input` the body used
fn decodeInPieces(input: []const u8, piece_len: usize, out: *std.Io.Writer) !usize {
    var d: ChunkedDecoder = .{};
    var i: usize = 0;
    while (!d.isDone()) {
        if (i == input.len) return error.EndOfStream; // input ended before the body did
        const end = @min(i + piece_len, input.len);
        const step = try d.feed(input[i..end]);
        try out.writeAll(step.data);
        i += step.consumed;
    }
    return i;
}

test "decode a simple body" {
    const input = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try std.testing.expectEqual(input.len, try decodeInPieces(input, input.len, &out));
    try std.testing.expectEqualStrings("hello world", out.buffered());
}

test "stops where the body ends" {
    const input = "5\r\nhello\r\n0\r\n\r\nGET / HTTP/1.1\r\n\r\n";
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const used = try decodeInPieces(input, input.len, &out);
    try std.testing.expectEqualStrings("GET / HTTP/1.1\r\n\r\n", input[used..]);
}

test "sizes are hex, extensions and trailers are skipped" {
    const input = "a;name=value;flag\r\n0123456789\r\n00F\r\nfifteen bytes!!\r\n0\r\nExpires: never\r\nX-Sum:1\r\n\r\n";
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    _ = try decodeInPieces(input, input.len, &out);
    try std.testing.expectEqualStrings("0123456789fifteen bytes!!", out.buffered());
}

test "remembers its place between pieces" {
    var d: ChunkedDecoder = .{};
    const first = try d.feed("5\r\nhel");
    try std.testing.expectEqual(6, first.consumed);
    try std.testing.expectEqualStrings("hel", first.data);
    try std.testing.expect(!d.isDone());

    const rest = "lo\r\n0\r\n\r\n";
    const second = try d.feed(rest);
    try std.testing.expectEqualStrings("lo", second.data);
    const third = try d.feed(rest[second.consumed..]); // feed what wasn't used yet
    try std.testing.expectEqualStrings("", third.data);
    try std.testing.expect(d.isDone());
}

test "any way of cutting the input gives the same body" {
    const input = "3;x=\"q\"\r\nabc\r\n10\r\n0123456789abcdef\r\n0\r\nT: v\r\n\r\n";
    for (1..input.len + 1) |piece_len| {
        errdefer std.debug.print("failed with pieces of {d} bytes\n", .{piece_len});
        var buf: [64]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        try std.testing.expectEqual(input.len, try decodeInPieces(input, piece_len, &out));
        try std.testing.expectEqualStrings("abc0123456789abcdef", out.buffered());
    }
}

test "rejects malformed chunked bodies" {
    const cases = [_]struct { []const u8, anyerror }{
        .{ "\r\nhello\r\n0\r\n\r\n", error.BadChunkSize }, // no size
        .{ "x\r\n", error.BadChunkSize },
        .{ "0x5\r\nhello\r\n0\r\n\r\n", error.BadChunkSize },
        .{ "+5\r\nhello\r\n0\r\n\r\n", error.BadChunkSize },
        .{ " 5\r\nhello\r\n0\r\n\r\n", error.BadChunkSize },
        .{ "5 \r\nhello\r\n0\r\n\r\n", error.BadChunkSize }, // space after size
        .{ "5\nhello\r\n0\r\n\r\n", error.BadChunkSize }, // bare LF
        .{ "10000000000000000\r\n", error.BadChunkSize }, // too big for u64
        .{ "5\rhello\r\n0\r\n\r\n", error.BadLineEnding }, // bare CR
        .{ "5;a\nb\r\nhello\r\n0\r\n\r\n", error.BadChunkExtension }, // LF hidden in an extension
        .{ "3\r\nhello\r\n0\r\n\r\n", error.BadLineEnding }, // more data than the size says
        .{ "5\r\nhello\n0\r\n\r\n", error.BadLineEnding }, // bare LF after data
        .{ "5\r\nhelloX\n0\r\n\r\n", error.BadLineEnding }, // junk then LF, found by the fuzzer
        .{ "0\r\nX-Sum 1\r\n\r\n", error.BadTrailer }, // no colon
        .{ "0\r\n folded\r\n\r\n", error.BadTrailer }, // obsolete line folding
        .{ "0\r\nX: a\x00\r\n\r\n", error.BadTrailer }, // control byte
        .{ "0\r\nX: a\rb\r\n\r\n", error.BadLineEnding }, // bare CR in a trailer
        .{ "0\r\n\r\r", error.BadLineEnding },
        .{ "5\r\nhel", error.EndOfStream }, // body never finished
    };
    for (cases) |case| {
        const input, const expected = case;
        for (1..input.len + 1) |piece_len| {
            errdefer std.debug.print("failed on: \"{f}\" in pieces of {d}\n", .{ std.zig.fmtString(input), piece_len });
            var buf: [64]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buf);
            try std.testing.expectError(expected, decodeInPieces(input, piece_len, &out));
        }
    }
}

test "biggest chunk size fits" {
    var d: ChunkedDecoder = .{};
    _ = try d.feed("ffffffffffffffff\r\n");
    try std.testing.expectEqual(std.math.maxInt(u64), d.remaining);
}

/// slow but obviously correct decoder for fuzzing, needs the whole body at once
fn decodeSlow(input: []const u8, out: *std.Io.Writer) !usize {
    var rest = input;
    // chunks, until the zero-size one
    while (true) {
        const line, rest = std.mem.cut(u8, rest, "\r\n") orelse return error.Bad;
        const size_text, const ext = std.mem.cutScalar(u8, line, ';') orelse .{ line, "" };
        for (size_text) |c| if (!std.ascii.isHex(c)) return error.Bad;
        for (ext) |c| if (!chars.isValueChar(c)) return error.Bad;
        const size = try std.fmt.parseInt(u64, size_text, 16);
        if (size == 0) break;
        if (size > rest.len) return error.Bad;
        try out.writeAll(rest[0..@intCast(size)]);
        rest = std.mem.cutPrefix(u8, rest[@intCast(size)..], "\r\n") orelse return error.Bad;
    }
    // trailers, until the empty line
    while (true) {
        const line, rest = std.mem.cut(u8, rest, "\r\n") orelse return error.Bad;
        if (line.len == 0) break;
        const name, const value = std.mem.cutScalar(u8, line, ':') orelse return error.Bad;
        if (name.len == 0) return error.Bad;
        for (name) |c| if (!chars.isTokenChar(c)) return error.Bad;
        for (value) |c| if (!chars.isValueChar(c)) return error.Bad;
    }
    return input.len - rest.len;
}

/// bytes that mean something in a chunked body, the fuzzer only picks these
const chunked_bytes = [_]std.testing.Smith.Weight{
    .rangeAtMost(u8, '0', '9', 1),
    .rangeAtMost(u8, 'a', 'f', 1),
    .rangeAtMost(u8, 'A', 'F', 1),
    .value(u8, '\r', 8),
    .value(u8, '\n', 8),
    .value(u8, ';', 2),
    .value(u8, ':', 2),
    .value(u8, '=', 1),
    .value(u8, ' ', 1),
    .value(u8, '\t', 1),
    .value(u8, 'x', 1), // not hex
    .value(u8, 0, 1), // control byte
    .value(u8, 0xff, 1), // not ASCII
};

fn fuzzFeed(_: void, smith: *std.testing.Smith) !void {
    var buf: [64]u8 = undefined;
    const input = buf[0..smith.sliceWeightedBytes(&buf, &chunked_bytes)];
    const piece_len = smith.valueRangeAtMost(u8, 1, 32);
    errdefer std.debug.print("failed on: \"{f}\" in pieces of {d}\n", .{ std.zig.fmtString(input), piece_len });

    var slow_buf: [64]u8 = undefined;
    var slow_out: std.Io.Writer = .fixed(&slow_buf);
    const slow = decodeSlow(input, &slow_out);

    var fast_buf: [64]u8 = undefined;
    var fast_out: std.Io.Writer = .fixed(&fast_buf);
    const fast = decodeInPieces(input, piece_len, &fast_out);

    // both must agree on whether the body is okay, where it ends, and what's in it
    if (slow) |slow_used| {
        try std.testing.expectEqual(slow_used, try fast);
        try std.testing.expectEqualStrings(slow_out.buffered(), fast_out.buffered());
    } else |_| {
        try std.testing.expect(std.meta.isError(fast));
    }
}

test "fuzz feed" {
    try std.testing.fuzz({}, fuzzFeed, .{
        .corpus = &.{
            sliceSeed("5\r\nabcde\r\n0\r\n\r\n"),
            sliceSeed("3;x=a\r\nabc\r\nA\r\n0123456789\r\n0\r\nE: f\r\n\r\n0"),
        },
    });
}
