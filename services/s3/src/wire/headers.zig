const std = @import("std");

pub const Header = std.http.Header;

pub const meta_prefix = "x-amz-meta-";

pub const MetaPair = struct { name: []const u8, value: []const u8 };

// Collects x-amz-meta-* request headers. `name` is the part after the prefix,
// lowercased; value duped as-is. Order preserved.
pub fn collectUserMeta(arena: std.mem.Allocator, hdrs: []const Header) ![]MetaPair {
    var out: std.ArrayList(MetaPair) = .empty;
    for (hdrs) |h| {
        if (h.name.len <= meta_prefix.len) continue;
        if (!std.ascii.startsWithIgnoreCase(h.name, meta_prefix)) continue;
        const suffix = h.name[meta_prefix.len..];
        const lower = try arena.alloc(u8, suffix.len);
        for (suffix, 0..) |c, i| lower[i] = std.ascii.toLower(c);
        try out.append(arena, .{ .name = lower, .value = try arena.dupe(u8, h.value) });
    }
    return out.items;
}

pub const Range = struct { start: ?u64, end: ?u64 };

// Parses a single-range "Range: bytes=N-M", "bytes=N-", or "bytes=-N" header.
// Returns null on anything we do not handle (multiple ranges, junk).
pub fn parseRange(value: []const u8) ?Range {
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    const spec = value[prefix.len..];
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return null; // multi-range unsupported
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const lo = spec[0..dash];
    const hi = spec[dash + 1 ..];

    var r: Range = .{ .start = null, .end = null };
    if (lo.len > 0) r.start = std.fmt.parseInt(u64, lo, 10) catch return null;
    if (hi.len > 0) r.end = std.fmt.parseInt(u64, hi, 10) catch return null;
    if (r.start == null and r.end == null) return null;
    return r;
}

const testing = std.testing;

test "parseRange forms" {
    try testing.expectEqual(Range{ .start = 10, .end = 19 }, parseRange("bytes=10-19").?);
    try testing.expectEqual(Range{ .start = 5, .end = null }, parseRange("bytes=5-").?);
    try testing.expectEqual(Range{ .start = null, .end = 100 }, parseRange("bytes=-100").?);
    try testing.expect(parseRange("bytes=") == null);
    try testing.expect(parseRange("items=1-2") == null);
    try testing.expect(parseRange("bytes=0-1,3-4") == null);
}

test "collectUserMeta" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hdrs = [_]Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-amz-meta-Foo", .value = "bar" },
        .{ .name = "X-Amz-Meta-Baz", .value = "qux" },
    };
    const got = try collectUserMeta(arena.allocator(), &hdrs);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("foo", got[0].name);
    try testing.expectEqualStrings("bar", got[0].value);
    try testing.expectEqualStrings("baz", got[1].name);
    try testing.expectEqualStrings("qux", got[1].value);
}
