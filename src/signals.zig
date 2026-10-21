//! notices Ctrl-C (SIGINT) and `kill` (SIGTERM) instead of dying from them

const std = @import("std");
const Io = std.Io;
const posix = std.posix;

/// set by the signal handler, read by everyone else
var stop_requested: std.atomic.Value(bool) = .init(false);

/// runs in the middle of whatever the program was doing, so it only sets the flag
fn handle(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    stop_requested.store(true, .release);
}

/// from now on SIGINT and SIGTERM set the flag instead of ending the process
pub fn install() void {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = handle },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &action, null);
    posix.sigaction(.TERM, &action, null);
}

/// whether SIGINT or SIGTERM has arrived since `install`
pub fn stopRequested() bool {
    return stop_requested.load(.acquire);
}

/// returns once SIGINT or SIGTERM has arrived. Returns at once if one already has
pub fn wait(io: Io) Io.Cancelable!void {
    while (!stopRequested()) {
        try io.sleep(.fromMilliseconds(50), .awake);
    }
}

// Tests
test "SIGTERM is noticed instead of ending the process" {
    const io = std.testing.io;
    install();
    try std.testing.expect(!stopRequested());

    try posix.raise(.TERM); // without `install` this line would end the test run
    try std.testing.expect(stopRequested());
    try wait(io); // already requested, so this returns at once
}
