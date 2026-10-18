//! test web server: answers requests with "Hello, World!"

const std = @import("std");
const Io = std.Io;
const ziggurat = @import("ziggurat");
const http = ziggurat.http;
const net = ziggurat.net;

const keep_alive_response = response("keep-alive");
const close_response = response("close");

/// how long a connection may wait for its next request
const idle_timeout: Io.Duration = .fromSeconds(10);
/// how long the whole request head may take to arrive
const head_timeout: Io.Duration = .fromSeconds(5);
/// how long the whole body may take to arrive
const body_timeout: Io.Duration = .fromSeconds(10);

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
    var timeout_reader = net.TimeoutReader.init(stream, io, &read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    const writer = &stream_writer.interface;

    defer writer.flush() catch {};

    // not just try, return correct errors from timeout reader
    while (handleRequest(&timeout_reader, writer) catch |err| switch (err) {
        error.ReadFailed => return timeout_reader.err.?,
        else => return err,
    }) {}
}

fn handleRequest(timeout_reader: *net.TimeoutReader, writer: *Io.Writer) !bool {
    const reader = &timeout_reader.interface;

    // idle: next request not here yet
    if (reader.bufferedLen() == 0) {
        // wait for client, so send response we already have now
        try writer.flush();
        timeout_reader.deadlineIn(idle_timeout);

        reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => return false, // client hung up
            error.ReadFailed => if (timeout_reader.err.? == error.Timeout) return false else return err, // timeout not error
        };
    }

    // head: one deadline for entire head
    timeout_reader.deadlineIn(head_timeout);
    const head_len = while (true) {
        if (http.Request.findHeadEnd(reader.buffered())) |len| break len;
        if (reader.bufferedLen() == reader.buffer.len) return error.HeadTooLarge;
        try writer.flush();
        try reader.fillMore();
    };

    var header_buf: [64]http.Request.Header = undefined;
    const request = try http.Request.parse(reader.buffered()[0..head_len], &header_buf);
    std.log.info("{t} {s} {t}, {d} headers, body: {any}", .{ request.method, request.target, request.version, request.headers.len, request.body });

    const keep_alive = request.keepAlive();

    reader.toss(head_len);

    // body: one deadline for reading or skipping body
    timeout_reader.deadlineIn(body_timeout);
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
