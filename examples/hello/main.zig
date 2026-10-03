//! test web server: answers requests with "Hello, World!"

const std = @import("std");
const Io = std.Io;
const ziggurat = @import("ziggurat");
const http = ziggurat.http;

const response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/plain\r\n" ++
    "Content-Length: 14\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "Hello, World!\n";

pub fn main(init: std.process.Init) !void {
    try serve(init.io);
}

/// accepts connections with each as its own task
fn serve(io: Io) !void {
    const address = try Io.net.IpAddress.parse("127.0.0.1", 3000);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.log.info("listening on http://{f}/", .{address});

    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.warn("accept failed: {t}", .{err});
            continue;
        };
        group.concurrent(io, serveConnection, .{ io, stream }) catch |err| {
            std.log.warn("can't start connection task: {t}", .{err});
            stream.close(io);
        };
    }
}

/// runs connection as own task, concurrent tasks cant return errors, so logged here then returns void
fn serveConnection(io: Io, stream: Io.net.Stream) void {
    handleConnection(io, stream) catch |err| {
        std.log.warn("connection failed: {t}", .{err});
    };
}

fn handleConnection(io: Io, stream: Io.net.Stream) !void {
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    const reader = &stream_reader.interface;

    // read until entire request head arrives
    const head_len = while (true) {
        if (http.Request.findHeadEnd(reader.buffered())) |len| break len;
        if (reader.bufferedLen() == read_buffer.len) return error.HeadTooLarge;
        try reader.fillMore();
    };
    var header_buf: [64]http.Request.Header = undefined;
    const request = try http.Request.parse(reader.buffered()[0..head_len], &header_buf);
    std.log.info("{t} {s} {t}, {d} headers", .{ request.method, request.target, request.version, request.headers.len });

    var write_buffer: [1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    const writer = &stream_writer.interface;
    try writer.writeAll(response);
    try writer.flush();
}
