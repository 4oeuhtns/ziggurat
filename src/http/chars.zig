//! which characters are allowed (RFC 9110)

/// `tchar` allowed in methods and header names (RFC 9110 section 5.6.2)
pub fn isTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// allowed in header values: tab, space, visible ASCII, and bytes 0x80 and up (RFC 9110 section 5.5)
pub fn isValueChar(c: u8) bool {
    return switch (c) {
        '\t', ' '...'~', 0x80...0xff => true,
        else => false,
    };
}
