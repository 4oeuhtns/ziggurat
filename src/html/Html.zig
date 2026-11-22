//! HTML writer

const std = @import("std");
const Io = std.Io;
const sliceSeed = @import("../fuzz.zig").sliceSeed;

const Html = @This();

/// max tag depth
pub const max_depth = 32;

pub const Error = Io.Writer.Error || error{
    /// more than `max_depth` tags at once
    TooDeep,
    /// `close` with no tag open
    NothingOpen,
    /// `finish` with tags still open
    Unclosed,
};

writer: *Io.Writer,
/// names of open tags
stack: [max_depth][]const u8 = undefined,
/// how many tags currently open
depth: usize = 0,

pub fn init(writer: *Io.Writer) Html {
    return .{ .writer = writer };
}

/// writes text, escapes special characters
pub fn text(h: *Html, bytes: []const u8) Error!void {
    try writeEscaped(h.writer, bytes);
}

/// writes raw bytes without escaping
pub fn raw(h: *Html, bytes: []const u8) Error!void {
    try h.writer.writeAll(bytes);
}

/// writes tag with attributes
pub fn open(h: *Html, comptime tag: []const u8, attrs: anytype) Error!void {
    if (h.depth == max_depth) return error.TooDeep;

    try h.writer.writeAll("<" ++ tag); // write the tag
    try writeAttrs(h.writer, attrs);
    try h.writer.writeByte(">");

    h.stack[h.depth] = tag; // update stack
    h.depth += 1;
}

/// writes tag with no end tag, like `img`, `meta`, `link` or `br`
pub fn empty(h: *Html, comptime tag: []const u8, attrs: anytype) Error!void {
    try h.writer.writeAll("<" ++ tag);
    try writeAttrs(h.writer, attrs);
    try h.writer.writeByte(">");
}

/// writes the end tag of innermost open tag
pub fn close(h: *Html) Error!void {
    if (h.depth == 0) return error.NothingOpen;

    h.depth -= 1;
    try h.writer.print("</{s}>", .{h.stack[h.depth]});
}

/// checks every tag is closed
pub fn finish(h: *Html) Error!void {
    if (h.depth > 0) return error.Unclosed;
}

/// writes `bytes`, with `& < > " '` replaced by their entities
fn writeEscaped(w: *Io.Writer, bytes: []const u8) Io.Writer.Error!void {
    var rest = bytes;
    while (std.mem.findAny(u8, rest, "&<>\"'")) |i| {
        const escape = switch (rest[i]) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => unreachable,
        };
        try w.writeAll(rest[0..i]);
        try w.writeAll(escape);
        rest = rest[i + 1 ..];
    }
    // after last special character
    try w.writeAll(rest);
}

/// writes field of `attrs` as `name="value"`
fn writeAttrs(w: *Io.Writer, attrs: anytype) Io.Writer.Error!void {
    // loop through fields of struct, known and unwrapped at compile time
    inline for (@typeInfo(@TypeOf(attrs)).@"struct".fields) |field| {
        const val = @field(attrs, field.name); // gets value of field attributes
        switch (@typeInfo(@TypeOf(val))) { // switch through type of val
            .pointer => {
                try w.writeAll(" " ++ field.name ++ "=\"");
                try writeEscaped(w, val);
                try w.writeByte('"');
            }, // []const u8
            .bool => if (val) try writeEscaped(w, " " ++ field.name),
            else => @compileError("attribute '" ++ field.name ++ "' must be text or a bool, not " ++ @typeName(@TypeOf(val))),
        }
    }
}

// Tests
test text {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var h: Html = .init(&w);
    try h.text("<b>Tom & \"Jerry's\"</b>");
    try std.testing.expectEqualStrings("&lt;b&gt;Tom &amp; &quot;Jerry&#39;s&quot;&lt;/b&gt;", w.buffered());
}

test raw {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var h: Html = .init(&w);
    try h.raw("<b>&amp;</b>");
    try std.testing.expectEqualStrings("<b>&amp;</b>", w.buffered());
}

test writeAttrs {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeAttrs(&w, .{ .href = "/?a=1&b=2", .@"data-x" = "\"", .hidden = true, .disabled = false });
    try std.testing.expectEqualStrings(" href=\"/?a=1&amp;b=2\" data-x=\"&quot;\" hidden", w.buffered());
}

test "open and close" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var h: Html = .init(&w);
    try h.open("p", .{});
    try h.text("hi");
    try h.close();
    try std.testing.expectEqualStrings("<p>hi</p>", w.buffered());
}

test empty {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var h: Html = .init(&w);
    try h.empty("img", .{ .src = "/a.png", .alt = "" });
    try std.testing.expectEqualStrings("<img src=\"/a.png\" alt=\"\">", w.buffered());
    try std.testing.expectEqual(0, h.depth);
}

test "nested tags close in reverse order" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var h: Html = .init(&w);
    try h.open("div", .{});
    try h.open("ul", .{});
    try h.open("li", .{});
    try h.close();
    try h.close();
    try h.close();
    try std.testing.expectEqualStrings("<div><ul><li></li></ul></div>", w.buffered());
}

test "closing with nothing open" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var h: Html = .init(&w);
    try std.testing.expectError(error.NothingOpen, h.close());
}

test "too deep" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var h: Html = .init(&w);
    for (0..max_depth) |_| try h.open("b", .{});
    try std.testing.expectError(error.TooDeep, h.open("b", .{}));
}

test finish {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var h: Html = .init(&w);
    try h.open("p", .{});
    try std.testing.expectError(error.Unclosed, h.finish());
    try h.close();
    try h.finish();
}

/// undoes `text`: turns the five entities back into their characters.
/// Fails on any other use of `&`
fn unescape(escaped: []const u8, out: []u8) ![]const u8 {
    const entities = [_]struct { []const u8, u8 }{
        .{ "&amp;", '&' }, .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&quot;", '"' }, .{ "&#39;", '\'' },
    };
    var i: usize = 0;
    var n: usize = 0;
    next: while (i < escaped.len) : (n += 1) {
        if (escaped[i] == '&') {
            for (entities) |e| {
                if (std.mem.startsWith(u8, escaped[i..], e[0])) {
                    out[n] = e[1];
                    i += e[0].len;
                    continue :next;
                }
            }
            return error.UnknownEntity;
        }
        out[n] = escaped[i];
        i += 1;
    }
    return out[0..n];
}

/// feeds random bytes to `text`, and checks that no tag can come out and nothing is lost
fn fuzzText(_: void, smith: *std.testing.Smith) !void {
    var input: [256]u8 = undefined;
    const len = smith.slice(&input);

    var buf: [256 * 6]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var h: Html = .init(&w);
    try h.text(input[0..len]);

    const out = w.buffered();
    try std.testing.expect(std.mem.findAny(u8, out, "<>\"'") == null);
    var back: [256]u8 = undefined;
    try std.testing.expectEqualStrings(input[0..len], try unescape(out, &back));
}

test "fuzz text never makes a tag" {
    try std.testing.fuzz({}, fuzzText, .{
        .corpus = &.{
            sliceSeed("<script>alert(1)</script>"),
            sliceSeed("Tom & \"Jerry's\" &amp;"),
        },
    });
}
