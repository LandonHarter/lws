const std = @import("std");
const queue = @import("../queue.zig");
const config = @import("config");

pub const Config = struct {
    target_arn: []const u8,
    max_receive_count: u32,
};

// Parses a RedrivePolicy JSON document. Returns null on malformed JSON, a
// missing/invalid deadLetterTargetArn, or a maxReceiveCount < 1. The returned
// target_arn slice borrows from a value parsed into `arena`.
pub fn parse(arena: std.mem.Allocator, json_str: []const u8) ?Config {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json_str, .{}) catch return null;
    if (parsed != .object) return null;
    const arn_v = parsed.object.get("deadLetterTargetArn") orelse return null;
    if (arn_v != .string) return null;
    const mrc_v = parsed.object.get("maxReceiveCount") orelse return null;
    const mrc: i64 = switch (mrc_v) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch return null,
        else => return null,
    };
    if (mrc < 1) return null;
    return .{ .target_arn = arn_v.string, .max_receive_count = @intCast(mrc) };
}

// Reads and parses the queue's RedrivePolicy attribute (stored as JSON or a
// string). Returns null when the attribute is absent or malformed.
pub fn fromQueue(arena: std.mem.Allocator, q: *queue.Queue) ?Config {
    const v = q.attributes.get("RedrivePolicy") orelse return null;
    const json_str = switch (v) {
        .json => |j| j,
        .string => |s| s,
        else => return null,
    };
    return parse(arena, json_str);
}

const testing = std.testing;

test "parse valid policy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = parse(arena.allocator(), "{\"deadLetterTargetArn\":\"arn:aws:sqs:us-east-1:000000000000:dlq\",\"maxReceiveCount\":3}").?;
    try testing.expectEqualStrings("arn:aws:sqs:us-east-1:000000000000:dlq", c.target_arn);
    try testing.expectEqual(@as(u32, 3), c.max_receive_count);
}

test "parse maxReceiveCount as string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = parse(arena.allocator(), "{\"deadLetterTargetArn\":\"a\",\"maxReceiveCount\":\"5\"}").?;
    try testing.expectEqual(@as(u32, 5), c.max_receive_count);
}

test "parse rejects malformed and incomplete" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(parse(a, "not json") == null);
    try testing.expect(parse(a, "{\"maxReceiveCount\":3}") == null); // no arn
    try testing.expect(parse(a, "{\"deadLetterTargetArn\":\"x\"}") == null); // no count
    try testing.expect(parse(a, "{\"deadLetterTargetArn\":\"x\",\"maxReceiveCount\":0}") == null); // count < 1
}
