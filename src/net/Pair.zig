//! two ends of a real TCP connection on this machine, for tests

const std = @import("std");
const Io = std.Io;
const Pair = @This();

client: Io.net.Stream,
server: Io.net.Stream,

pub fn open(io: Io) !Pair {
    // port 0 asks the system for any free port
    var listener = try Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{});
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    errdefer client.close(io);
    return .{ .client = client, .server = try listener.accept(io) };
}

pub fn close(pair: Pair, io: Io) void {
    pair.client.close(io);
    pair.server.close(io);
}

/// sends `bytes` from the client end
pub fn send(pair: Pair, io: Io, bytes: []const u8) !void {
    var writer = pair.client.writer(io, &.{});
    try writer.interface.writeAll(bytes);
}
