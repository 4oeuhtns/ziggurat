//! networking

const std = @import("std");

pub const TimeoutReader = @import("net/TimeoutReader.zig");

test {
    std.testing.refAllDecls(@This());
}
