const std = @import("std");

// Decodes an aws-chunked body (STREAMING-AWS4-HMAC-SHA256-PAYLOAD and the
// unsigned-trailer variant). Framing:
//   <hex-chunk-size>;chunk-signature=<hex>\r\n
//   <chunk-size bytes>\r\n
//   ...
//   0;chunk-signature=<hex>\r\n
//   \r\n
// Trailing key=value lines on the signed-trailer variant are ignored.
pub fn decode(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (pos < raw.len) {
        const line_end = std.mem.indexOfPos(u8, raw, pos, "\r\n") orelse return error.MalformedChunk;
        const line = raw[pos..line_end];
        pos = line_end + 2;

        const semi = std.mem.indexOfScalar(u8, line, ';');
        const size_hex = if (semi) |s| line[0..s] else line;
        const size = std.fmt.parseInt(usize, size_hex, 16) catch return error.MalformedChunk;

        if (size == 0) break;
        if (pos + size + 2 > raw.len) return error.MalformedChunk;
        try out.appendSlice(arena, raw[pos .. pos + size]);
        pos += size;
        if (raw[pos] != '\r' or raw[pos + 1] != '\n') return error.MalformedChunk;
        pos += 2;
    }
    return out.items;
}

const testing = std.testing;

test "single chunk plus terminator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const raw = "5;chunk-signature=abc\r\nhello\r\n0;chunk-signature=def\r\n\r\n";
    const got = try decode(arena.allocator(), raw);
    try testing.expectEqualStrings("hello", got);
}

test "multiple chunks of varying size" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const raw =
        "3;chunk-signature=11\r\nabc\r\n" ++
        "5;chunk-signature=22\r\ndefgh\r\n" ++
        "1;chunk-signature=33\r\ni\r\n" ++
        "0;chunk-signature=44\r\n\r\n";
    const got = try decode(arena.allocator(), raw);
    try testing.expectEqualStrings("abcdefghi", got);
}

test "empty body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const raw = "0;chunk-signature=abc\r\n\r\n";
    const got = try decode(arena.allocator(), raw);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "truncated body errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const raw = "5;chunk-signature=abc\r\nhel";
    try testing.expectError(error.MalformedChunk, decode(arena.allocator(), raw));
}
