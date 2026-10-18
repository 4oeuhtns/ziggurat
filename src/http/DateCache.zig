const std = @import("std");
const Io = std.Io;
const DateCache = @This();

pub const len = 29; // length of http date response
pub const weekdays: [7][3]u8 = .{
    "Thu".*,
    "Fri".*,
    "Sat".*,
    "Sun".*,
    "Mon".*,
    "Tue".*,
    "Wed".*,
};
pub const months: [12][3]u8 = .{
    "Jan".*,
    "Feb".*,
    "Mar".*,
    "Apr".*,
    "May".*,
    "Jun".*,
    "Jul".*,
    "Aug".*,
    "Sep".*,
    "Oct".*,
    "Nov".*,
    "Dec".*,
};

second: i64 = -1,
text: [len]u8 = undefined,

pub fn format(seconds: u64) [len]u8 {
    // ex. Tue, 13 Oct 2026 21:32:16 GMT
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    var buf: [len]u8 = undefined;

    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();

    _ = std.fmt.bufPrint(&buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        weekdays[day.day % 7],
        month_day.day_index + 1,
        months[month_day.month.numeric() - 1],
        year_day.year,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    }) catch unreachable;

    return buf;
}

pub fn get(cache: *DateCache, seconds: i64) *const [len]u8 {
    if (cache.second == seconds) {
        return &cache.text;
    }
    cache.text = format(@intCast(seconds));
    cache.second = seconds;
    return &cache.text;
}

pub fn now(cache: *DateCache, io: Io) *const [len]u8 {
    const s = Io.Clock.real.now(io).toSeconds();
    return get(cache, s);
}

// Tests
test format {
    const cases = [_]struct { u64, []const u8 }{
        .{ 0, "Thu, 01 Jan 1970 00:00:00 GMT" },
        .{ 784111777, "Sun, 06 Nov 1994 08:49:37 GMT" }, // the RFC's own example
        .{ 951782400, "Tue, 29 Feb 2000 00:00:00 GMT" }, // leap day in a century year
        .{ 1709251199, "Thu, 29 Feb 2024 23:59:59 GMT" },
        .{ 1709251200, "Fri, 01 Mar 2024 00:00:00 GMT" },
        .{ 1798761599, "Thu, 31 Dec 2026 23:59:59 GMT" },
        .{ 4102444800, "Fri, 01 Jan 2100 00:00:00 GMT" },
    };
    for (cases) |case| {
        const seconds, const expected = case;
        try std.testing.expectEqualStrings(expected, &format(seconds));
    }
}

test "formats again only when the second changes" {
    var cache: DateCache = .{};
    try std.testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", cache.get(784111777));

    // scribble on the cached text: if `get` formats again, the scribble disappears
    cache.text[0] = '?';
    try std.testing.expectEqualStrings("?un, 06 Nov 1994 08:49:37 GMT", cache.get(784111777));
    try std.testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:38 GMT", cache.get(784111778));
}

test now {
    var cache: DateCache = .{};
    const text = cache.now(std.testing.io);
    try std.testing.expectEqualStrings(" GMT", text[25..]);
    try std.testing.expect(cache.second > 1_700_000_000); // after 2023
}
