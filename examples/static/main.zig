//! test static website, bakes pages straight into the binary

const std = @import("std");
const z = @import("ziggurat");

// bake in website during compilation
const page = @embedFile("index.html");

const Router = z.http.Router(.{
    .{ .GET, "/", index },
});

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    z.signals.install();
    var quiet = false;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quiet")) quiet = true;
    }

    var storage: [4096]z.http.AccessLog.Entry = undefined;
    var out_buffer: [16 * 1024]u8 = undefined;
    var access_log: z.http.AccessLog.Stdout = undefined;
    try access_log.start(io, &storage, &out_buffer);
    defer access_log.stop(io);

    try z.http.serve(io, Router, .{ .port = 3001, .access_log = if (quiet) null else &access_log.log }, z.signals.wait);
}

/// returns index.html
fn index(_: *const z.http.Request, res: *z.http.Response) !void {
    res.content_type = z.http.contentType("index.html");
    try res.send(page);
}
