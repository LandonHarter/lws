const std = @import("std");

pub fn writeArn(w: anytype, region: []const u8, account: []const u8, name: []const u8) !void {
    try w.print("arn:aws:sqs:{s}:{s}:{s}", .{ region, account, name });
}

pub fn writeQueueUrl(w: anytype, host: []const u8, account: []const u8, name: []const u8) !void {
    try w.print("http://{s}/{s}/{s}", .{ host, account, name });
}

pub const ParseError = error{InvalidQueueUrl};

pub fn parseQueueUrl(url: []const u8) ParseError![]const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];

    // strip host[:port] prefix
    if (std.mem.indexOfScalar(u8, rest, '/')) |i| {
        rest = rest[i + 1 ..];
    } else {
        return ParseError.InvalidQueueUrl;
    }

    // drop trailing slash
    while (rest.len > 0 and rest[rest.len - 1] == '/') rest = rest[0 .. rest.len - 1];
    if (rest.len == 0) return ParseError.InvalidQueueUrl;

    // last path segment is the queue name
    if (std.mem.lastIndexOfScalar(u8, rest, '/')) |i| {
        const name = rest[i + 1 ..];
        if (name.len == 0) return ParseError.InvalidQueueUrl;
        return name;
    }
    return ParseError.InvalidQueueUrl;
}

const testing = std.testing;

test "writeArn format" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeArn(&w, "us-east-1", "000000000000", "foo");
    try testing.expectEqualStrings("arn:aws:sqs:us-east-1:000000000000:foo", w.buffered());
}

test "writeQueueUrl format" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeQueueUrl(&w, "127.0.0.1:9324", "000000000000", "foo");
    try testing.expectEqualStrings("http://127.0.0.1:9324/000000000000/foo", w.buffered());
}

test "parseQueueUrl extracts name" {
    try testing.expectEqualStrings("foo", try parseQueueUrl("http://x/000000000000/foo"));
    try testing.expectEqualStrings("foo", try parseQueueUrl("http://127.0.0.1:9324/000000000000/foo"));
    try testing.expectEqualStrings("foo", try parseQueueUrl("https://sqs.us-east-1.amazonaws.com/000000000000/foo"));
    try testing.expectEqualStrings("foo", try parseQueueUrl("http://x/000000000000/foo/"));
}

test "parseQueueUrl rejects malformed" {
    try testing.expectError(ParseError.InvalidQueueUrl, parseQueueUrl("http://x"));
    try testing.expectError(ParseError.InvalidQueueUrl, parseQueueUrl("http://x/"));
}
