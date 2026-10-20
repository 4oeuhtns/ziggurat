//! sends each request to its handler, with the route list checked at compile time

const std = @import("std");
const Io = std.Io;
const Request = @import("Request.zig");
const Response = @import("Response.zig");

/// what every handler looks like
pub const Handler = fn (req: *const Request, res: *Response) anyerror!void;

/// a type whose `handle` runs the route that matches a request.
/// `routes` is a tuple of `.{ method, path, handler }`
pub fn Router(comptime routes: anytype) type {
    comptime check(routes);
    return struct {
        /// runs the handler for `req`, or answers 404 or 405
        pub fn handle(req: *const Request, res: *Response) anyerror!void {
            const path = req.path();
            // pass 1: a route with this method and this path
            inline for (routes) |route| {
                const method: Request.Method, const pattern: []const u8, const handler = route;
                if (req.method == method and std.mem.eql(u8, path, pattern)) return handler(req, res);
            }

            // pass 2: HEAD with no route of its own uses the GET route for this path
            if (req.method == .HEAD) {
                inline for (routes) |route| {
                    const method: Request.Method, const pattern: []const u8, const handler = route;
                    if (method == .GET and std.mem.eql(u8, path, pattern)) return handler(req, res);
                }
            }
            // pass 3: some route has this path, but not this method: 405 with an `Allow` header
            inline for (routes) |route| {
                _, const pattern: []const u8, _ = route;
                if (std.mem.eql(u8, path, pattern)) {
                    res.status = .method_not_allowed;
                    res.headers = &.{.{ .name = "Allow", .value = comptime allowed(routes, pattern) }};
                    return try res.send("Method Not Allowed\n");
                }
            }
            // after all passes: nothing has this path
            res.status = .not_found;
            try res.send("Not Found\n");
        }
    };
}

/// stops the build with a message naming the route, when the route list has a mistake
fn check(comptime routes: anytype) void {
    for (routes, 0..) |route, i| {
        const method: Request.Method, const pattern: []const u8, _ = route;
        const name = @tagName(method) ++ " " ++ pattern; // "GET /home"
        if (!std.mem.startsWith(u8, pattern, "/")) @compileError("route path must start with '/': " ++ name);
        if (std.mem.findScalar(u8, pattern, '?') != null) @compileError("route path must not contain '?': " ++ name);
        for (0..i) |j| {
            const earlier_method: Request.Method, const earlier_pattern: []const u8, _ = routes[j];
            if (method == earlier_method and std.mem.eql(u8, pattern, earlier_pattern)) @compileError("duplicate route: " ++ name);
        }
    }
}

/// the `Allow` text for `pattern`, like "GET, POST, HEAD". Only ever runs at compile time
fn allowed(comptime routes: anytype, comptime pattern: []const u8) []const u8 {
    var text: []const u8 = "";
    var get = false;
    var head = false;
    for (routes) |route| {
        const method: Request.Method, const route_pattern: []const u8, _ = route;
        if (!std.mem.eql(u8, pattern, route_pattern)) continue;
        if (text.len > 0) text = text ++ ", ";
        text = text ++ @tagName(method);
        if (method == .GET) get = true;
        if (method == .HEAD) head = true;
    }
    if (get and !head) text = text ++ ", HEAD";
    return text;
}

// Tests
const test_date = "Sun, 06 Nov 1994 08:49:37 GMT";

fn home(_: *const Request, res: *Response) !void {
    try res.send("home");
}

fn listNotes(req: *const Request, res: *Response) !void {
    try res.send(req.query() orelse "all notes");
}

fn addNote(_: *const Request, res: *Response) !void {
    try res.send("added");
}

fn broken(_: *const Request, _: *Response) !void {
    return error.Oops;
}

const TestRouter = Router(.{
    .{ .GET, "/", home },
    .{ .GET, "/notes", listNotes },
    .{ .POST, "/notes", addNote },
    .{ .DELETE, "/notes", broken },
});

/// routes one request line through `TestRouter`, returns everything it wrote
fn testRequest(comptime request_line: []const u8, out: []u8) ![]u8 {
    var header_buf: [4]Request.Header = undefined;
    const req = try Request.parse(request_line ++ " HTTP/1.1\r\nHost: test\r\n\r\n", &header_buf);
    var writer: Io.Writer = .fixed(out);
    var res: Response = .{ .writer = &writer, .date = test_date };
    try TestRouter.handle(&req, &res);
    return writer.buffered();
}

test "routes by method and path" {
    var buf: [512]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try testRequest("GET /", &buf), "\r\n\r\nhome"));
    try std.testing.expect(std.mem.endsWith(u8, try testRequest("GET /notes", &buf), "\r\n\r\nall notes"));
    try std.testing.expect(std.mem.endsWith(u8, try testRequest("POST /notes", &buf), "\r\n\r\nadded"));
}

test "the query isn't part of the path" {
    var buf: [512]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try testRequest("GET /notes?tag=zig", &buf), "\r\n\r\ntag=zig"));
    try std.testing.expect(std.mem.endsWith(u8, try testRequest("GET /?x", &buf), "\r\n\r\nhome"));
}

test "an unknown path is 404" {
    var buf: [512]u8 = undefined;
    for ([_][]const u8{ try testRequest("GET /nope", &buf), try testRequest("GET /notes/", &buf), try testRequest("GET /Notes", &buf) }) |reply| {
        try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 404 Not Found\r\n"));
    }
}

test "a known path with the wrong method is 405, and says what would work" {
    var buf: [512]u8 = undefined;
    const reply = try testRequest("PUT /notes", &buf);
    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try std.testing.expect(std.mem.find(u8, reply, "\r\nAllow: GET, POST, DELETE, HEAD\r\n") != null);

    const home_reply = try testRequest("POST /", &buf);
    try std.testing.expect(std.mem.find(u8, home_reply, "\r\nAllow: GET, HEAD\r\n") != null);
}

test "HEAD is answered by the GET handler" {
    var buf: [512]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try testRequest("HEAD /", &buf), "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.startsWith(u8, try testRequest("HEAD /nope", &buf), "HTTP/1.1 404 Not Found\r\n"));
}

test "a handler's error comes back to the caller" {
    var buf: [512]u8 = undefined;
    try std.testing.expectError(error.Oops, testRequest("DELETE /notes", &buf));
}
