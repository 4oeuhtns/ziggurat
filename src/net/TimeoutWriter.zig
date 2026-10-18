//! writes to a socket, giving up at a deadline

const std = @import("std");
const Io = std.Io;
const TimeoutWriter = @This();

io: Io,
stream: Io.net.Stream,
/// what callers write through
interface: Io.Writer,
/// when writes give up
timeout: Io.Timeout,
/// why the last write failed
err: ?Error,

/// why a write failed: the wait (Timeout, Canceled, ...) or the send (ConnectionResetByPeer, ...)
pub const Error = Io.net.Stream.Writer.Error || Io.OperateTimeoutError;

/// a writer with no deadline yet
pub fn init(stream: Io.net.Stream, io: Io, buffer: []u8) TimeoutWriter {
    return .{
        .io = io,
        .stream = stream,
        .interface = .{
            .vtable = &.{ .drain = drainImpl },
            .buffer = buffer,
        },
        .timeout = .none,
        .err = null,
    };
}

/// writes from now on must start within `duration`, counted from this call
pub fn deadlineIn(w: *TimeoutWriter, duration: Io.Duration) void {
    const dur: Io.Clock.Duration = .{ .raw = duration, .clock = .awake };
    w.timeout = .{ .deadline = Io.Clock.Timestamp.fromNow(w.io, dur) };
}

fn drainImpl(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    // 1. find the TimeoutWriter around `io_w`
    // 2. unless the timeout is `.none`: wait for room with an empty `file_write_streaming`
    // 3. send with `netWrite`, exactly as `Io.net.Stream.Writer.drain` does
    const w: *TimeoutWriter = @alignCast(@fieldParentPtr("interface", io_w));
    const io = w.io;
    const buffered = io_w.buffered();
    const handle = w.stream.socket.handle;

    if (w.timeout != .none) {
        _ = io.operateTimeout(.{
            .file_write_streaming = .{
                .file = .{ .handle = handle, .flags = .{ .nonblocking = false } },
                .data = &.{""}, // a write of nothing
            },
        }, w.timeout) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
    }

    const n = io.vtable.netWrite(io.userdata, handle, buffered, data, splat) catch |err| {
        w.err = err;
        return error.WriteFailed;
    };
    return io_w.consume(n);
}

// Tests
const Pair = @import("Pair.zig");

test "writes reach the peer" {
    const io = std.testing.io;
    const pair = try Pair.open(io);
    defer pair.close(io);

    var buf: [64]u8 = undefined;
    var writer: TimeoutWriter = .init(pair.server, io, &buf);
    writer.deadlineIn(.fromSeconds(5));
    try writer.interface.writeAll("hello");
    try writer.interface.flush();

    var read_buf: [64]u8 = undefined;
    var reader = pair.client.reader(io, &read_buf);
    try std.testing.expectEqualStrings("hello", try reader.interface.take(5));
}

test "gives up when the peer never reads" {
    const io = std.testing.io;
    const pair = try Pair.open(io);
    defer pair.close(io);

    var writer: TimeoutWriter = .init(pair.server, io, &.{});
    const chunk: [1024]u8 = @splat('x');

    // the client never reads, so the system's buffers fill up and then nothing more fits
    var sent: usize = 0;
    const start = Io.Clock.awake.now(io);
    while (true) : (sent += chunk.len) {
        writer.deadlineIn(.fromMilliseconds(100));
        writer.interface.writeAll(&chunk) catch break;
        if (start.untilNow(io, .awake).toSeconds() >= 5) return error.NeverFilledUp;
    }
    try std.testing.expect(writer.err.? == error.Timeout);
    try std.testing.expect(sent > 0);
}

test "a peer that hung up is an error, not a crash" {
    const io = std.testing.io;
    const pair = try Pair.open(io);
    defer pair.server.close(io);

    var writer: TimeoutWriter = .init(pair.server, io, &.{});
    pair.client.close(io);

    // the first write after a hang-up can still seem to work, so keep going
    const chunk: [1024]u8 = @splat('x');
    for (0..100) |_| {
        writer.deadlineIn(.fromSeconds(5));
        writer.interface.writeAll(&chunk) catch break;
        try io.sleep(.fromMilliseconds(1), .awake);
    } else return error.NeverFailed;
    try std.testing.expect(writer.err.? != error.Timeout);
}
