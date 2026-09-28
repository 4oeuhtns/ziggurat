const std = @import("std");
const Io = std.Io;
const ziggurat = @import("ziggurat");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var request = "GET /index.html HTTP/1.1\r\nHost: example.com\r\nUser-Agent: bench\r\nAccept: */*\r\n\r\n".*;
    const iters = 10_000_000;

    const start = Io.Clock.awake.now(io);
    for (0..iters) |_| {
        std.mem.doNotOptimizeAway(&request);
        std.mem.doNotOptimizeAway(ziggurat.http.findHeadEnd(&request));
    }
    const elapsed = start.untilNow(io, .awake);

    var buf: [256]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &stdout_writer.interface;
    const ns_per_op = @as(f64, @floatFromInt(elapsed.nanoseconds)) / iters;
    try out.print("findHeadEnd: {d:.2} ns/op ({d} bytes)\n", .{ ns_per_op, request.len });
    try out.flush();
}
