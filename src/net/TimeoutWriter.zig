//! writes to a socket, giving up at a deadline

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const TimeoutWriter = @This();

/// does the writes and reads the clock
io: Io,
/// the socket being written
stream: Io.net.Stream,
/// what callers write through
interface: Io.Writer,
/// how long writes may wait for room, counted from the first wait. `null`: no limit
wait_limit: ?Io.Duration,
/// when writes give up, `.none` until a write first has to wait
timeout: Io.Timeout,
/// why the last write failed with `error.WriteFailed`, `null` if none has
err: ?Error,

/// why a write failed: the wait (Timeout, Canceled, ...) or the send (ConnectionResetByPeer, ...)
pub const Error = Io.net.Stream.Writer.Error || Io.OperateTimeoutError;

/// a writer over `stream` with no deadline yet, `buffer` holds bytes written but not yet sent
pub fn init(stream: Io.net.Stream, io: Io, buffer: []u8) TimeoutWriter {
    return .{
        .io = io,
        .stream = stream,
        .interface = .{
            .vtable = &.{ .drain = drainImpl },
            .buffer = buffer,
        },
        .wait_limit = null,
        .timeout = .none,
        .err = null,
    };
}

/// from now on, writes that have to wait for room give up `duration` after the first wait
/// the deadline is a fixed moment: later waits don't push it back. Writes that don't wait never read the clock
pub fn deadlineIn(w: *TimeoutWriter, duration: Io.Duration) void {
    w.wait_limit = duration;
    w.timeout = .none; // the deadline is set by the first wait
}

/// sends the buffer and `data` in one `sendmsg`, waiting for room first if the socket is full
fn drainImpl(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    // 1. find the TimeoutWriter around `io_w`
    // 2. try to send without waiting: usually the socket has room, so that's the whole job
    // 3. no room: start the deadline if it hasn't started, and wait for room with an empty `file_write_streaming`
    // 4. send with `netWrite`, exactly as `Io.net.Stream.Writer.drain` does
    const w: *TimeoutWriter = @alignCast(@fieldParentPtr("interface", io_w));
    const io = w.io;
    const buffered = io_w.buffered();
    const handle = w.stream.socket.handle;

    if (sendNow(handle, buffered, data, splat)) |n| return io_w.consume(n);

    if (w.wait_limit) |limit| {
        if (w.timeout == .none) {
            w.timeout = .{ .deadline = .fromNow(io, .{ .raw = limit, .clock = .awake }) };
        }
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

/// sends what fits right now without waiting, and returns how many bytes went
/// `null` when nothing went, for any reason (full, interrupted, a real error): the caller then waits and sends normally,
/// and the normal send reports a real error. Linux only: macOS ignores `MSG_DONTWAIT` on a blocking socket and would wait with no deadline
fn sendNow(handle: Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) ?usize {
    if (builtin.os.tag != .linux) return null;
    if (splat > 1) return null; // a repeated last slice: rare, leave it to `netWrite`

    // the same bytes `netWrite` would send: `header`, then `data`, with the last slice sent `splat` (0 or 1) times
    var iovecs: [16]posix.iovec_const = undefined;
    var len: usize = 0;
    const last = data.len - 1;
    addIovec(&iovecs, &len, header);
    for (data[0..last]) |bytes| addIovec(&iovecs, &len, bytes);
    if (splat == 1) addIovec(&iovecs, &len, data[last]);
    if (len == 0) return null;

    const msg: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iovecs,
        .iovlen = @intCast(len),
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    const rc = posix.system.sendmsg(handle, &msg, posix.MSG.NOSIGNAL | posix.MSG.DONTWAIT);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => null,
    };
}

/// adds `bytes` to the `len` iovecs in use, skipping empty slices. Once all are in use it adds nothing,
/// so what's sent is always a prefix of the bytes, and the writer sends the rest later
fn addIovec(iovecs: []posix.iovec_const, len: *usize, bytes: []const u8) void {
    if (bytes.len == 0 or len.* == iovecs.len) return;
    iovecs[len.*] = .{ .base = bytes.ptr, .len = bytes.len };
    len.* += 1;
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
