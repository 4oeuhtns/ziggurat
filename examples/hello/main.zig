//! test web server: a site made of two routes, on the public API

const std = @import("std");
const z = @import("ziggurat");

const Router = z.http.Router(.{
    .{ .GET, "/", hello },
    .{ .POST, "/echo", echo },
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

    try z.http.serve(io, Router, .{ .port = 3000, .access_log = if (quiet) null else &access_log.log }, z.signals.wait);
}

/// answers "Hello, World!"
fn hello(_: *const z.http.Request, res: *z.http.Response) !void {
    try res.send("Hello, World!\n");
}

/// sends back the first kilobyte of the body, with the request's `Content-Type` if it has one
fn echo(req: *const z.http.Request, res: *z.http.Response) !void {
    var buf: [1024]u8 = undefined;
    const n = try req.reader.readSliceShort(&buf);
    if (req.header("content-type")) |val| res.content_type = val;
    try res.send(buf[0..n]);
}
