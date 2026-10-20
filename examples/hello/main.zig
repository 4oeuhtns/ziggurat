//! test web server: a site made of two routes, on the public API

const std = @import("std");
const z = @import("ziggurat");

const Router = z.http.Router(.{
    .{ .GET, "/", hello },
    .{ .POST, "/echo", echo },
});

pub fn main(init: std.process.Init) !void {
    try z.http.serve(init.io, Router, .{ .port = 3000 });
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
