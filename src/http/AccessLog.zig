//! the access log: requests drop entries into a queue, and one task writes them out in batches

const std = @import("std");
const Io = std.Io;
const Request = @import("Request.zig");
const AccessLog = @This();

queue: Io.Queue(Entry),
/// how many entries were thrown away because the queue was full or closed
dropped: std.atomic.Value(u64) = .init(0),

/// one request. Holds no pointers, so it stays right after the request's buffers are reused
pub const Entry = struct {
    /// longer targets are cut off
    pub const max_target = 100;

    method: Request.Method,
    status: u16,
    micros: u64,
    target_bytes: [max_target]u8,
    used: u8,

    /// copies `full_target` in, cut off at `max_target` bytes
    pub fn init(method: Request.Method, full_target: []const u8, status: u16, micros: u64) Entry {
        const len = @min(max_target, full_target.len);
        var entry: Entry = .{
            .method = method,
            .status = status,
            .micros = micros,
            .target_bytes = undefined,
            .used = len,
        };
        @memcpy(entry.target_bytes[0..len], full_target[0..len]);
        return entry;
    }

    /// slice target_bytes from 0 up to `used`
    pub fn target(entry: *const Entry) []const u8 {
        return entry.target_bytes[0..entry.used];
    }
};

/// a log whose queue holds `storage.len` entries
pub fn init(storage: []Entry) AccessLog {
    return .{ .queue = .init(storage) };
}

/// queues `entry`. Never waits: when there's no room, the entry is dropped and counted
pub fn record(log: *AccessLog, io: Io, entry: Entry) void {
    const added = log.queue.putUncancelable(io, &.{entry}, 0) catch 0;
    if (added == 0) _ = log.dropped.fetchAdd(1, .monotonic);
}

/// no more entries after this
pub fn close(log: *AccessLog, io: Io) void {
    log.queue.close(io);
}

/// writes entries to `out` in batches, until the log is closed and empty
pub fn run(log: *AccessLog, io: Io, out: *Io.Writer) Io.Writer.Error!void {
    var batch: [64]Entry = undefined;
    while (true) {
        var n = log.queue.getUncancelable(io, &batch, 1) catch return;
        io.sleep(.fromMilliseconds(20), .awake) catch {}; // wait for more entries, catch `error{Canceled}`

        while (n > 0) {
            for (batch[0..n]) |entry| {
                try out.print("{t} {s} {d} {d}us\n", .{ entry.method, entry.target(), entry.status, entry.micros });
            }
            n = log.queue.getUncancelable(io, &batch, 0) catch 0;
        }
        try out.flush(); // flush only after entire batch is cleared
    }
}

/// an access log with its own task, writing to standard output.
/// Make it with `= undefined`, then `start` it where it will stay: the task keeps pointers into it
pub const Stdout = struct {
    log: AccessLog,
    out: Io.File.Writer,
    task: Io.Future(Io.Writer.Error!void),

    /// sets up the log and the writer in place, and starts the task that writes
    pub fn start(s: *Stdout, io: Io, storage: []Entry, buffer: []u8) Io.ConcurrentError!void {
        s.log = .init(storage);
        s.out = Io.File.stdout().writerStreaming(io, buffer);
        s.task = try io.concurrent(run, .{ &s.log, io, &s.out.interface });
    }

    /// closes the log, then write what's left
    pub fn stop(s: *Stdout, io: Io) void {
        s.log.close(io);
        s.task.await(io) catch {};
    }
};

// Tests
test "writes one line per entry" {
    const io = std.testing.io;
    var storage: [8]Entry = undefined;
    var log: AccessLog = .init(&storage);
    log.record(io, .init(.GET, "/", 200, 150));
    log.record(io, .init(.POST, "/notes?tag=zig", 404, 2000));
    log.close(io);

    var buf: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buf);
    try log.run(io, &out); // closed, so this returns once the two entries are written
    try std.testing.expectEqualStrings("GET / 200 150us\n" ++
        "POST /notes?tag=zig 404 2000us\n", out.buffered());
}

test "a full queue drops entries instead of making requests wait" {
    const io = std.testing.io;
    var storage: [2]Entry = undefined;
    var log: AccessLog = .init(&storage);
    for (0..5) |i| log.record(io, .init(.GET, "/", 200, i));
    try std.testing.expectEqual(3, log.dropped.load(.monotonic));
    log.close(io);

    var buf: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buf);
    try log.run(io, &out);
    try std.testing.expectEqualStrings("GET / 200 0us\nGET / 200 1us\n", out.buffered());
}

test "a long target is cut off" {
    const io = std.testing.io;
    var storage: [2]Entry = undefined;
    var log: AccessLog = .init(&storage);
    log.record(io, .init(.GET, "/" ++ "a" ** 300, 200, 1));
    log.close(io);

    var buf: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buf);
    try log.run(io, &out);
    try std.testing.expectEqualStrings("GET /" ++ "a" ** (Entry.max_target - 1) ++ " 200 1us\n", out.buffered());
}

/// counts how often it's asked to hand bytes to the "system"
const CountingWriter = struct {
    interface: Io.Writer,
    drains: usize = 0,
    lines: usize = 0,

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const counting: *CountingWriter = @alignCast(@fieldParentPtr("interface", w));
        counting.drains += 1;
        counting.lines += std.mem.countScalar(u8, w.buffered(), '\n');
        w.end = 0;
        for (data[0 .. data.len - 1]) |bytes| counting.lines += std.mem.countScalar(u8, bytes, '\n');
        counting.lines += splat * std.mem.countScalar(u8, data[data.len - 1], '\n');
        return Io.Writer.countSplat(data, splat);
    }
};

test "entries that waited together are written together" {
    const io = std.testing.io;
    var storage: [32]Entry = undefined;
    var log: AccessLog = .init(&storage);
    for (0..20) |i| log.record(io, .init(.GET, "/", 200, i));
    log.close(io);

    var buf: [4096]u8 = undefined;
    var out: CountingWriter = .{ .interface = .{ .vtable = &.{ .drain = CountingWriter.drain }, .buffer = &buf } };
    try log.run(io, &out.interface);
    try std.testing.expectEqual(20, out.lines);
    try std.testing.expectEqual(1, out.drains); // twenty lines, one write
}

test "nothing is lost between a busy server and the writer task" {
    const io = std.testing.io;
    var storage: [64]Entry = undefined;
    var log: AccessLog = .init(&storage);

    var buf: [4096]u8 = undefined;
    var out: CountingWriter = .{ .interface = .{ .vtable = &.{ .drain = CountingWriter.drain }, .buffer = &buf } };
    var writing = try io.concurrent(run, .{ &log, io, &out.interface });

    var recorded: usize = 0;
    for (0..500) |i| {
        log.record(io, .init(.GET, "/", 200, i));
        recorded += 1;
        if (i % 50 == 0) try io.sleep(.fromMilliseconds(1), .awake); // let the writer catch up now and then
    }
    log.close(io);
    try writing.await(io);

    try std.testing.expectEqual(recorded, out.lines + log.dropped.load(.monotonic));
    try std.testing.expect(out.lines > 0);
    try std.testing.expect(out.drains < out.lines); // batches, not one write per line
}
