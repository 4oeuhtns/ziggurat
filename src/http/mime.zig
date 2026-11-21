//! picks content type from file extension

const std = @import("std");

/// one row of the table: a file extension, without the dot, and its type
const Row = struct { ext: []const u8, type: []const u8 };

const table = [_]Row{
    .{ .ext = "html", .type = "text/html; charset=utf-8" },
    .{ .ext = "htm", .type = "text/html; charset=utf-8" },
    .{ .ext = "css", .type = "text/css; charset=utf-8" },
    .{ .ext = "js", .type = "text/javascript; charset=utf-8" },
    .{ .ext = "mjs", .type = "text/javascript; charset=utf-8" },
    .{ .ext = "json", .type = "application/json" },
    .{ .ext = "txt", .type = "text/plain; charset=utf-8" },
    .{ .ext = "svg", .type = "image/svg+xml" },
    .{ .ext = "png", .type = "image/png" },
    .{ .ext = "jpg", .type = "image/jpeg" },
    .{ .ext = "jpeg", .type = "image/jpeg" },
    .{ .ext = "gif", .type = "image/gif" },
    .{ .ext = "webp", .type = "image/webp" },
    .{ .ext = "avif", .type = "image/avif" },
    .{ .ext = "ico", .type = "image/x-icon" },
    .{ .ext = "woff2", .type = "font/woff2" },
    .{ .ext = "wasm", .type = "application/wasm" },
};

/// `Content-Type` for file from extension, default is `application/octet-stream`
pub fn contentType(path: []const u8) []const u8 {
    const i_slash = std.mem.findScalarLast(u8, path, '/');
    const name = if (i_slash) |i| path[i + 1 ..] else path; // if i exists, use it to get the file name

    const i_dot = std.mem.findScalarLast(u8, name, '.');
    const ext = if (i_dot) |i| name[i + 1 ..] else return "application/octet-stream"; // if i exists, use it to get the extension

    for (table) |row| { // loop through the table and compare extensions
        if (std.ascii.eqlIgnoreCase(row.ext, ext)) return row.type;
    }

    return "application/octet-stream";
}

// Tests
test contentType {
    const rows = [_][2][]const u8{
        .{ "index.html", "text/html; charset=utf-8" },
        .{ "old.htm", "text/html; charset=utf-8" },
        .{ "style.css", "text/css; charset=utf-8" },
        .{ "app.js", "text/javascript; charset=utf-8" },
        .{ "app.mjs", "text/javascript; charset=utf-8" },
        .{ "data.json", "application/json" },
        .{ "robots.txt", "text/plain; charset=utf-8" },
        .{ "logo.svg", "image/svg+xml" },
        .{ "photo.png", "image/png" },
        .{ "photo.jpg", "image/jpeg" },
        .{ "photo.jpeg", "image/jpeg" },
        .{ "anim.gif", "image/gif" },
        .{ "photo.webp", "image/webp" },
        .{ "photo.avif", "image/avif" },
        .{ "favicon.ico", "image/x-icon" },
        .{ "font.woff2", "font/woff2" },
        .{ "app.wasm", "application/wasm" },
    };
    for (rows) |row| try std.testing.expectEqualStrings(row[1], contentType(row[0]));
}

test "contentType ignores case and looks only at the last extension" {
    try std.testing.expectEqualStrings("text/css; charset=utf-8", contentType("STYLE.CSS"));
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", contentType("app.min.js"));
    try std.testing.expectEqualStrings("application/octet-stream", contentType("archive.tar.gz"));
}

test "contentType with no extension" {
    try std.testing.expectEqualStrings("application/octet-stream", contentType("Makefile"));
    // a dot in a folder name isn't an extension
    try std.testing.expectEqualStrings("application/octet-stream", contentType("v1.2/readme"));
    try std.testing.expectEqualStrings("text/html; charset=utf-8", contentType(".html"));
}
