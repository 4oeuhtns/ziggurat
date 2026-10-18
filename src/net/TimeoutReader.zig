//! reads from a socket, giving up when a deadline passes

const std = @import("std");
const Io = std.Io;
const TimeoutReader = @This();

/// does the reads and reads the clock
io: Io,
/// the socket being read
stream: Io.net.Stream,
/// what callers read through
interface: Io.Reader,
/// when reads give up, `.none` until `deadlineIn` is called
timeout: Io.Timeout,
/// why the last read failed with `error.ReadFailed`, `null` if none has
err: ?Error,

/// why a read failed: the wait (`Timeout`, `Canceled`, ...) or the read itself (`ConnectionResetByPeer`, ...)
pub const Error = Io.Operation.FileReadStreaming.UnendingError || Io.OperateTimeoutError;

/// a reader over `stream` with no deadline yet, `buffer` holds bytes read but not yet taken
pub fn init(stream: Io.net.Stream, io: Io, buffer: []u8) TimeoutReader {
    return .{
        .io = io,
        .stream = stream,
        .interface = .{
            .vtable = &.{ .stream = streamImpl },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
        .timeout = .none,
        .err = null,
    };
}

/// reads from now on must finish within `duration`, counted from this call
/// the deadline is a fixed moment: reads that get bytes don't push it back
pub fn deadlineIn(r: *TimeoutReader, duration: Io.Duration) void {
    const dur: Io.Clock.Duration = .{ .raw = duration, .clock = .awake };
    r.timeout = .{ .deadline = Io.Clock.Timestamp.fromNow(r.io, dur) };
}

fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize { // errors: EndOfStream, ReadFailed and WriteFailed
    const r: *TimeoutReader = @alignCast(@fieldParentPtr("interface", io_r)); // find TimeoutReader this interface is a part of
    const dest = limit.slice(try io_w.writableSliceGreedy(1)); // greedily try to get all empty memory, at least 1 byte, limited by limit.slice()
    const data: [1][]u8 = .{dest};

    // try using reader's operateTimeout, use file_read_streaming operation with socket
    const result = r.io.operateTimeout(.{ .file_read_streaming = .{
        .file = .{ .handle = r.stream.socket.handle, .flags = .{ .nonblocking = false } },
        .data = &data,
    } }, r.timeout) catch |err| {
        r.err = err;
        return error.ReadFailed;
    };

    // check the result of file_read_streaming, either byte count or error
    const n = result.file_read_streaming catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        else => |e| {
            r.err = e;
            return error.ReadFailed;
        },
    };

    // tell writer you filled n bytes, return n
    io_w.advance(n);
    return n;
}

// Tests
const Pair = @import("Pair.zig");

test "reads what the peer sent" {
    const io = std.testing.io;
    const pair = try Pair.open(io);
    defer pair.close(io);

    var buf: [64]u8 = undefined;
    var reader: TimeoutReader = .init(pair.server, io, &buf);
    reader.deadlineIn(.fromSeconds(5));

    try pair.send(io, "hello");
    try std.testing.expectEqualStrings("hello", try reader.interface.take(5));
}

test "gives up when the peer stays silent" {
    const io = std.testing.io;
    const pair = try Pair.open(io);
    defer pair.close(io);

    var buf: [64]u8 = undefined;
    var reader: TimeoutReader = .init(pair.server, io, &buf);

    const start = Io.Clock.awake.now(io);
    reader.deadlineIn(.fromMilliseconds(50));
    try std.testing.expectError(error.ReadFailed, reader.interface.takeByte());
    try std.testing.expect(reader.err.? == error.Timeout);
    // poll counts in whole milliseconds, so allow it to fire a little early
    try std.testing.expect(start.untilNow(io, .awake).toMilliseconds() >= 45);
}

test "a deadline is a point in time, not an allowance per read" {
    const io = std.testing.io;
    const pair = try Pair.open(io);
    defer pair.close(io);

    var buf: [64]u8 = undefined;
    var reader: TimeoutReader = .init(pair.server, io, &buf);

    const start = Io.Clock.awake.now(io);
    reader.deadlineIn(.fromMilliseconds(150));

    // a slow client: one byte now, one byte later, then nothing
    try pair.send(io, "a");
    try std.testing.expectEqual('a', try reader.interface.takeByte());
    try io.sleep(.fromMilliseconds(100), .awake);
    try pair.send(io, "b");
    try std.testing.expectEqual('b', try reader.interface.takeByte());

    // each read was quick, but the deadline never moved
    try std.testing.expectError(error.ReadFailed, reader.interface.takeByte());
    try std.testing.expect(reader.err.? == error.Timeout);
    const elapsed = start.untilNow(io, .awake).toMilliseconds();
    try std.testing.expect(elapsed >= 145 and elapsed < 250);
}

test "a closed connection is the end of the stream, not a timeout" {
    const io = std.testing.io;
    const pair = try Pair.open(io);
    defer pair.server.close(io);

    var buf: [64]u8 = undefined;
    var reader: TimeoutReader = .init(pair.server, io, &buf);
    reader.deadlineIn(.fromSeconds(5));

    try pair.send(io, "bye");
    pair.client.close(io);

    try std.testing.expectEqualStrings("bye", try reader.interface.take(3));
    try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
    try std.testing.expectEqual(null, reader.err);
}
