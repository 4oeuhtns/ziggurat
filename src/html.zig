//! HTML

const std = @import("std");

pub const Html = @import("html/Html.zig");

test {
    std.testing.refAllDecls(@This());
}
