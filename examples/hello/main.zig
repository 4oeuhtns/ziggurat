//! test web server: answers requests with "Hello, World!"

const std = @import("std");
const Io = std.Io;
const ziggurat = @import("ziggurat");
const http = ziggurat.http;

const keep_alive_response = response("keep-alive");
const close_response = response("close");

/// biggest request body we accept
const max_body = 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    try serve(init.io);
}

/// builds response, connection is `keep-alive` or `close`
fn response(comptime connection: []const u8) []const u8 {
    return "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 14\r\n" ++
        "Connection: " ++ connection ++ "\r\n" ++
        "\r\n" ++
        "Hello, World!\n";
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

    var write_buffer: [1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    const writer = &stream_writer.interface;

    defer writer.flush() catch {};

    while (try handleRequest(reader, writer)) {}
}

fn handleRequest(reader: *Io.Reader, writer: *Io.Writer) !bool {
    // read until entire request head arrives
    const head_len = while (true) {
        if (http.Request.findHeadEnd(reader.buffered())) |len| break len;
        if (reader.bufferedLen() == reader.buffer.len) return error.HeadTooLarge;
        // wait for client, so send response we already have now
        try writer.flush();

        reader.fillMore() catch |err| switch (err) {
            // hang up between request -> done, not error
            error.EndOfStream => if (reader.bufferedLen() == 0) return false else return err,
            else => return err,
        };
    };
    var header_buf: [64]http.Request.Header = undefined;
    const request = try http.Request.parse(reader.buffered()[0..head_len], &header_buf);
    std.log.info("{t} {s} {t}, {d} headers, body: {any}", .{ request.method, request.target, request.version, request.headers.len, request.body });

    const keep_alive = request.keepAlive();

    reader.toss(head_len);
    switch (request.body) {
        .none => {},
        .length => |n| {
            if (n > max_body) return error.BodyTooLarge;
            try reader.discardAll(@intCast(n));
        },
        .chunked => {
            // counts every byte, not just data so large extensions or trailer can't go over `max_body`
            var decoder: http.ChunkedDecoder = .{};
            var used: usize = 0;
            while (!decoder.isDone()) {
                const step = try decoder.feed((try reader.peekGreedy(1)));
                reader.toss(step.consumed);
                used += step.consumed;
                if (used > max_body) return error.BodyTooLarge;
            }
        },
    }

    try writer.writeAll(if (keep_alive) keep_alive_response else close_response);
    return keep_alive;
}
