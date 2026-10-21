//! ziggurat: a web framework that implements every layer of the web in zig

const std = @import("std");
pub const http = @import("http.zig");
pub const net = @import("net.zig");
pub const signals = @import("signals.zig");

test {
    std.testing.refAllDecls(@This()); // test all public structs/files in this struct, all files are structs
}
