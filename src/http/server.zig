//! the HTTP server: accepts connections and answers each request with `R.handle`

const std = @import("std");
const Io = std.Io;
const net = @import("../net.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const Status = Response.Status;
const DateCache = @import("DateCache.zig");
const BodyReader = @import("BodyReader.zig");

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    /// 0: any free port
    port: u16 = 3000,
    idle_timeout: Io.Duration = .fromSeconds(10),
    head_timeout: Io.Duration = .fromSeconds(5),
    body_timeout: Io.Duration = .fromSeconds(10),
    write_timeout: Io.Duration = .fromSeconds(10),
    max_body: u64 = 1024 * 1024,
};

/// biggest request head
pub const max_head = 4096;
pub const max_headers = 64;

/// a server that answers every request with `R.handle(req, res)`
pub fn Server(comptime R: type) type {
    return struct {
        io: Io,
        options: Options,
        listener: Io.net.Server,
        /// one task per connection
        group: Io.Group,

        const Self = @This();

        /// starts listening. Connections wait in the system's queue until `run`
        pub fn init(io: Io, options: Options) !Self {
            const listen_address = try Io.net.IpAddress.parse(options.host, options.port);
            return .{
                .io = io,
                .options = options,
                .listener = try listen_address.listen(io, .{ .reuse_address = true }),
                .group = .init,
            };
        }

        /// cancels every connection task, waits for them, stops listening
        pub fn deinit(server: *Self) void {
            server.group.cancel(server.io);
            server.listener.deinit(server.io);
        }

        /// where it really listens, with the real port
        pub fn address(server: *const Self) Io.net.IpAddress {
            return server.listener.socket.address;
        }

        /// accepts connections until canceled, then returns `error.Canceled`
        pub fn run(server: *Self) Io.Cancelable!void {
            while (true) {
                const stream = server.listener.accept(server.io) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => {
                        std.log.warn("accept failed: {t}", .{err});
                        continue;
                    },
                };
                server.group.concurrent(server.io, serveConnection, .{ server, stream }) catch |err| {
                    std.log.warn("can't start connection task: {t}", .{err});
                    stream.close(server.io);
                };
            }
        }

        /// one connection, as its own task. Tasks can't return errors, so it logs them (but not `error.Canceled`)
        fn serveConnection(server: *Self, stream: Io.net.Stream) void {
            handleConnection(server, stream) catch |err| switch (err) {
                error.Canceled => {},
                else => std.log.warn("connection failed: {t}", .{err}),
            };
        }

        /// one connection: its reader, writer and date cache, and the loop over its requests
        fn handleConnection(server: *Self, stream: Io.net.Stream) !void {
            defer stream.close(server.io);

            var read_buffer: [max_head + 4096]u8 = undefined; // if the head is too big, still leave space for body
            var timeout_reader = net.TimeoutReader.init(stream, server.io, &read_buffer);

            var write_buffer: [1024]u8 = undefined;
            var timeout_writer = net.TimeoutWriter.init(stream, server.io, &write_buffer);

            var date: DateCache = .{};

            // not just try, return correct errors from timeout reader
            while (handleRequest(server, &timeout_reader, &timeout_writer, &date) catch |err| {
                const reason = switch (err) {
                    error.ReadFailed => timeout_reader.err.?,
                    error.WriteFailed => return timeout_writer.err.?,
                    else => err,
                };

                if (Status.fromError(reason)) |s| {
                    timeout_writer.deadlineIn(server.options.write_timeout);
                    var res: Response = .{
                        .writer = &timeout_writer.interface,
                        .date = date.now(server.io),
                        .keep_alive = false,
                        .status = s,
                    };
                    try res.send(s.phrase());
                }
                try server.flush(&timeout_writer);
                return reason;
            }) {}

            try server.flush(&timeout_writer);
        }

        /// one request. Returns whether to keep the connection open
        fn handleRequest(server: *Self, reader: *net.TimeoutReader, writer: *net.TimeoutWriter, date: *DateCache) !bool {
            const r = &reader.interface;

            // idle: next request not here yet
            if (r.bufferedLen() == 0) {
                // wait for client, so send response we already have now
                try server.flush(writer);
                reader.deadlineIn(server.options.idle_timeout);

                r.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return false, // client hung up
                    error.ReadFailed => if (reader.err.? == error.Timeout) return false else return err, // timeout not error
                };
            }

            // head: one deadline for entire head
            reader.deadlineIn(server.options.head_timeout);
            const head_len = while (true) {
                if (Request.findHeadEnd(r.buffered())) |len| break len;
                if (r.bufferedLen() >= max_head) return error.HeadTooLarge;
                try server.flush(writer);
                try r.fillMore();
            };
            if (head_len > max_head) return error.HeadTooLarge;

            var header_buf: [max_headers]Request.Header = undefined;
            var request = try Request.parse(r.buffered()[0..head_len], &header_buf);
            std.log.info("{t} {s} {t}, {d} headers, body: {any}", .{ request.method, request.target, request.version, request.headers.len, request.body });

            const keep_alive = request.keepAlive();

            _ = try request.host(); // verify requests host

            const whole = r.buffer;
            setAside(r, head_len); // makes sure that when reading body we don't overwrite the head

            var body_buf: [4096]u8 = undefined;
            var body_reader = BodyReader.init(r, request.body, server.options.max_body, &body_buf);
            // body only used by handlers, server itself doesn't need info in body
            request.reader = &body_reader.interface;

            // body: one deadline for reading or skipping body
            reader.deadlineIn(server.options.body_timeout);

            writer.deadlineIn(server.options.write_timeout);
            var res: Response = .{
                .writer = &writer.interface,
                .date = date.now(server.io),
                .keep_alive = keep_alive,
                .omit_body = request.method == .HEAD, // omits body if it is a HEAD request
            };

            R.handle(&request, &res) catch |err| {
                if (err == error.WriteFailed) return error.WriteFailed;
                if (res.sent) { // close connection, don't send again
                    std.log.warn("{t} {s}: handler failed after answering: {t}", .{ request.method, request.target, err });
                    return false;
                }
                if (err == error.ReadFailed) return body_reader.err orelse error.ReadFailed;
                std.log.warn("{t} {s}: handler failed: {t}", .{ request.method, request.target, err });
                return error.HandlerFailed;
            };
            if (!res.sent) {
                std.log.warn("{t} {s}: handler sent no answer", .{ request.method, request.target });
                return error.HandlerFailed;
            }

            _ = body_reader.interface.discardRemaining() catch return false; // clear rest of body from reader before next request

            giveBack(r, whole);
            return keep_alive;
        }

        /// sends what's buffered, giving the client `write_timeout` to take it
        fn flush(server: *Self, writer: *net.TimeoutWriter) !void {
            writer.deadlineIn(server.options.write_timeout);
            try writer.interface.flush();
        }
    };
}

/// `init`, log the address, `run`, with `deinit` deferred
pub fn serve(io: Io, comptime R: type, options: Options) !void {
    var server: Server(R) = try .init(io, options);
    defer server.deinit();
    std.log.info("listening on http://{f}/", .{server.address()});
    try server.run();
}

/// hides the first `n` buffered bytes from `r`
fn setAside(r: *Io.Reader, n: usize) void {
    std.debug.assert(r.seek == 0); // the head starts at 0
    r.buffer = r.buffer[n..]; // the reader now sees only what's after the head
    r.end -= n; // `end` counts from the buffer's start, which just moved n bytes right
}

/// undoes `setAside`: `r` gets `whole` back, with its unread bytes moved to the front
fn giveBack(r: *Io.Reader, whole: []u8) void {
    const unread = r.buffered(); // the start of the next request, if one came in early
    @memmove(whole[0..unread.len], unread); // slide it to the left edge
    r.buffer = whole;
    r.seek = 0;
    r.end = unread.len;
}

// Tests
const Router = @import("router.zig").Router;

fn hello(_: *const Request, res: *Response) !void {
    try res.send("Hello, World!\n");
}

/// sends the body back
fn echo(req: *const Request, res: *Response) !void {
    var buf: [256]u8 = undefined;
    const n = try req.reader.readSliceShort(&buf);
    try res.send(buf[0..n]);
}

/// reads the whole body first, and only then looks at a header
fn tag(req: *const Request, res: *Response) !void {
    _ = try req.reader.discardRemaining();
    try res.send(req.header("x-tag") orelse "no tag");
}

/// answers without reading the body at all
fn ignore(_: *const Request, res: *Response) !void {
    try res.send("ignored");
}

fn fail(_: *const Request, _: *Response) !void {
    return error.Oops;
}

fn silent(_: *const Request, _: *Response) !void {}

const TestServer = Server(Router(.{
    .{ .GET, "/", hello },
    .{ .POST, "/echo", echo },
    .{ .POST, "/tag", tag },
    .{ .POST, "/ignore", ignore },
    .{ .GET, "/fail", fail },
    .{ .GET, "/silent", silent },
}));

/// connects to `address`, sends `request`, and returns everything the server says before it hangs up
fn exchange(io: Io, address: Io.net.IpAddress, request: []const u8, out: []u8) ![]u8 {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(request);
    // "that's all from me": the server sees the end at once, instead of waiting for its idle timeout
    try stream.shutdown(io, .send);

    // a server that never hangs up fails the test instead of hanging it
    var reader: net.TimeoutReader = .init(stream, io, &.{});
    reader.deadlineIn(.fromSeconds(5));
    var reply: Io.Writer = .fixed(out);
    _ = try reader.interface.streamRemaining(&reply);
    return reply.buffered();
}

const Reply = struct {
    status: u16,
    head: []const u8,
    body: []const u8,
};

/// takes one response off the front of `bytes`
fn nextReply(bytes: *[]const u8) !Reply {
    const head_len = Request.findHeadEnd(bytes.*) orelse return error.NoReply;
    const head = bytes.*[0..head_len];
    const marker = "\r\nContent-Length: ";
    const length_start = (std.mem.find(u8, head, marker) orelse return error.NoContentLength) + marker.len;
    const length_end = std.mem.findPos(u8, head, length_start, "\r\n").?;
    const body_len = try std.fmt.parseInt(usize, head[length_start..length_end], 10);
    defer bytes.* = bytes.*[head_len + body_len ..];
    return .{
        .status = try std.fmt.parseInt(u16, head[9..12], 10),
        .head = head,
        .body = bytes.*[head_len..][0..body_len],
    };
}

test "answers a request" {
    const io = std.testing.io;
    var server: TestServer = try .init(io, .{ .port = 0 });
    defer server.deinit();
    var running = try io.concurrent(TestServer.run, .{&server});
    defer running.cancel(io) catch {};

    var buf: [1024]u8 = undefined;
    var rest: []const u8 = try exchange(io, server.address(), "GET / HTTP/1.1\r\nHost: test\r\n\r\n", &buf);
    const reply = try nextReply(&rest);
    try std.testing.expectEqual(200, reply.status);
    try std.testing.expectEqualStrings("Hello, World!\n", reply.body);
    try std.testing.expect(std.mem.find(u8, reply.head, "\r\nDate: ") != null);
    try std.testing.expectEqualStrings("", rest);
}

test "answers pipelined requests in order, then closes when asked" {
    const io = std.testing.io;
    var server: TestServer = try .init(io, .{ .port = 0 });
    defer server.deinit();
    var running = try io.concurrent(TestServer.run, .{&server});
    defer running.cancel(io) catch {};

    var buf: [1024]u8 = undefined;
    var rest: []const u8 = try exchange(io, server.address(), "POST /echo HTTP/1.1\r\nHost: test\r\nContent-Length: 3\r\n\r\none" ++
        "POST /echo HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n3\r\ntwo\r\n0\r\n\r\n" ++
        "GET / HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n" ++
        "GET / HTTP/1.1\r\nHost: test\r\n\r\n", &buf); // after `close`, so never answered

    try std.testing.expectEqualStrings("one", (try nextReply(&rest)).body);
    try std.testing.expectEqualStrings("two", (try nextReply(&rest)).body);
    const last = try nextReply(&rest);
    try std.testing.expectEqualStrings("Hello, World!\n", last.body);
    try std.testing.expect(std.mem.find(u8, last.head, "\r\nConnection: close\r\n") != null);
    try std.testing.expectEqualStrings("", rest);
}

test "a body the handler didn't read doesn't become the next request" {
    const io = std.testing.io;
    var server: TestServer = try .init(io, .{ .port = 0 });
    defer server.deinit();
    var running = try io.concurrent(TestServer.run, .{&server});
    defer running.cancel(io) catch {};

    var buf: [1024]u8 = undefined;
    var rest: []const u8 = try exchange(io, server.address(), "POST /ignore HTTP/1.1\r\nHost: test\r\nContent-Length: 31\r\n\r\nGET /fail HTTP/1.1\r\nHost: x\r\n\r\n" ++ // a body dressed up as a request
        "POST /ignore HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n" ++
        "GET / HTTP/1.1\r\nHost: test\r\n\r\n", &buf);

    try std.testing.expectEqualStrings("ignored", (try nextReply(&rest)).body);
    try std.testing.expectEqualStrings("ignored", (try nextReply(&rest)).body);
    try std.testing.expectEqualStrings("Hello, World!\n", (try nextReply(&rest)).body);
    try std.testing.expectEqualStrings("", rest);
}

test "headers are still readable after a long body" {
    const io = std.testing.io;
    var server: TestServer = try .init(io, .{ .port = 0 });
    defer server.deinit();
    var running = try io.concurrent(TestServer.run, .{&server});
    defer running.cancel(io) catch {};

    // long enough to go around the server's read buffer several times
    const body = "x" ** 20_000;
    var buf: [1024]u8 = undefined;
    var rest: []const u8 = try exchange(io, server.address(), "POST /tag HTTP/1.1\r\nHost: test\r\nX-Tag: still here\r\nContent-Length: 20000\r\n\r\n" ++ body ++
        "POST /tag HTTP/1.1\r\nHost: test\r\nX-Tag: me too\r\nTransfer-Encoding: chunked\r\n\r\n4e20\r\n" ++ body ++ "\r\n0\r\n\r\n", &buf);

    try std.testing.expectEqualStrings("still here", (try nextReply(&rest)).body);
    try std.testing.expectEqualStrings("me too", (try nextReply(&rest)).body);
}

test "HEAD gets the head only" {
    const io = std.testing.io;
    var server: TestServer = try .init(io, .{ .port = 0 });
    defer server.deinit();
    var running = try io.concurrent(TestServer.run, .{&server});
    defer running.cancel(io) catch {};

    var buf: [1024]u8 = undefined;
    const reply = try exchange(io, server.address(), "HEAD / HTTP/1.1\r\nHost: test\r\n\r\n", &buf);
    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.find(u8, reply, "\r\nContent-Length: 14\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\n"));
}

test "requests that break the rules get an error status and a closed connection" {
    std.testing.log_level = .err; // these requests are meant to fail, the server's warnings would only be noise
    const io = std.testing.io;
    var server: TestServer = try .init(io, .{ .port = 0, .max_body = 16 });
    defer server.deinit();
    var running = try io.concurrent(TestServer.run, .{&server});
    defer running.cancel(io) catch {};

    const cases = [_]struct { []const u8, u16 }{
        .{ "GET / HTTP/1.1\r\n\r\n", 400 }, // no Host
        .{ "GET  / HTTP/1.1\r\nHost: test\r\n\r\n", 400 },
        .{ "POST /echo HTTP/1.1\r\nHost: test\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n", 400 },
        .{ "POST /echo HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", 400 },
        .{ "POST /echo HTTP/1.1\r\nHost: test\r\nContent-Length: 5\r\n\r\nabc", 400 }, // hung up mid-body
        .{ "GET /nope HTTP/1.1\r\nHost: test\r\n\r\n", 404 },
        .{ "PUT / HTTP/1.1\r\nHost: test\r\n\r\n", 405 },
        .{ "POST /echo HTTP/1.1\r\nHost: test\r\nContent-Length: 17\r\n\r\n", 413 },
        .{ "POST /ignore HTTP/1.1\r\nHost: test\r\nContent-Length: 17\r\n\r\n", 200 }, // nobody read it, nobody minds
        .{ "GET / HTTP/1.1\r\nHost: test\r\nX: " ++ "x" ** max_head ++ "\r\n\r\n", 431 },
        .{ "GET /fail HTTP/1.1\r\nHost: test\r\n\r\n", 500 },
        .{ "GET /silent HTTP/1.1\r\nHost: test\r\n\r\n", 500 },
        .{ "BREW / HTTP/1.1\r\nHost: test\r\n\r\n", 501 },
        .{ "GET / HTTP/2.0\r\nHost: test\r\n\r\n", 505 },
    };
    for (cases) |case| {
        const request, const expected = case;
        errdefer std.debug.print("failed on: \"{f}\"\n", .{std.zig.fmtString(request[0..@min(request.len, 80)])});
        var buf: [1024]u8 = undefined;
        var rest: []const u8 = try exchange(io, server.address(), request, &buf);
        const reply = try nextReply(&rest);
        try std.testing.expectEqual(expected, reply.status);
        try std.testing.expectEqualStrings("", rest);
    }
}

test "a client that stalls mid-head gets 408, an idle one is dropped quietly" {
    std.testing.log_level = .err;
    const io = std.testing.io;
    var server: TestServer = try .init(io, .{
        .port = 0,
        .idle_timeout = .fromMilliseconds(100),
        .head_timeout = .fromMilliseconds(100),
    });
    defer server.deinit();
    var running = try io.concurrent(TestServer.run, .{&server});
    defer running.cancel(io) catch {};

    // these clients stay connected and wait, so they can't use `exchange`
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "GET / HTTP/1.1\r\nHost: te", "HTTP/1.1 408 Request Timeout\r\n" },
        .{ "", "" },
    };
    for (cases) |case| {
        const request, const expected_start = case;
        const stream = try server.address().connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var writer = stream.writer(io, &.{});
        try writer.interface.writeAll(request);

        var reader: net.TimeoutReader = .init(stream, io, &.{});
        reader.deadlineIn(.fromSeconds(5));
        var buf: [1024]u8 = undefined;
        var reply: Io.Writer = .fixed(&buf);
        _ = try reader.interface.streamRemaining(&reply);
        try std.testing.expect(std.mem.startsWith(u8, reply.buffered(), expected_start));
        if (expected_start.len == 0) try std.testing.expectEqualStrings("", reply.buffered());
    }
}
