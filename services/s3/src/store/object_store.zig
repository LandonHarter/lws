const std = @import("std");

pub const UserMeta = std.StringArrayHashMapUnmanaged([]const u8);

pub const ObjectMeta = struct {
    key: []const u8,
    etag: [32]u8, // lowercase md5 hex; for multipart the rendered etag is etag ++ "-N"
    multipart_part_count: u16 = 0, // 0 = single-shot; >0 means etag is rendered with "-N" suffix
    size: u64,
    content_type: []const u8,
    storage_class: []const u8 = "STANDARD",
    user_meta: UserMeta = .empty,
    last_modified_ms: i64,
};

// Per-bucket key index. Keys are kept sorted so listing is a forward scan.
// All strings and ObjectMeta nodes are owned by the bucket arena passed at
// init, so there is no explicit free path (the arena is freed wholesale when
// the bucket is dropped).
pub const ObjectIndex = struct {
    arena: std.mem.Allocator,
    keys: std.ArrayList([]const u8) = .empty,
    meta_by_key: std.StringArrayHashMapUnmanaged(*ObjectMeta) = .empty,

    pub fn init(arena: std.mem.Allocator) ObjectIndex {
        return .{ .arena = arena };
    }

    // Insert or replace. The key and all string fields of `meta` must already
    // live in (or outlive) the index arena; the key is duped defensively so the
    // sorted list and map share one owned copy.
    pub fn put(self: *ObjectIndex, meta: ObjectMeta) !void {
        if (self.meta_by_key.get(meta.key)) |existing| {
            const owned_key = existing.key;
            existing.* = meta;
            existing.key = owned_key;
            return;
        }
        const node = try self.arena.create(ObjectMeta);
        node.* = meta;
        const owned_key = try self.arena.dupe(u8, meta.key);
        node.key = owned_key;
        try self.meta_by_key.put(self.arena, owned_key, node);

        const idx = self.insertionIndex(owned_key);
        try self.keys.insert(self.arena, idx, owned_key);
    }

    pub fn get(self: *ObjectIndex, key: []const u8) ?*ObjectMeta {
        return self.meta_by_key.get(key);
    }

    pub fn remove(self: *ObjectIndex, key: []const u8) bool {
        if (!self.meta_by_key.swapRemove(key)) return false;
        const idx = self.findIndex(key) orelse return true;
        _ = self.keys.orderedRemove(idx);
        return true;
    }

    pub fn count(self: *const ObjectIndex) usize {
        return self.keys.items.len;
    }

    pub fn totalBytes(self: *const ObjectIndex) u64 {
        var total: u64 = 0;
        for (self.keys.items) |k| {
            if (self.meta_by_key.get(k)) |m| total += m.size;
        }
        return total;
    }

    // Keys strictly greater than `after_key` (exclusive), in sorted order. When
    // `after_key` is null, returns all keys. Used for start-after / marker /
    // continuation-token listing; delimiter handling lives in the listing handler.
    pub fn rangeFrom(self: *ObjectIndex, after_key: ?[]const u8) []const []const u8 {
        const items = self.keys.items;
        if (after_key) |ak| {
            const start = self.insertionIndex(ak);
            // insertionIndex returns the first slot >= ak; skip an exact match.
            if (start < items.len and std.mem.eql(u8, items[start], ak)) {
                return items[start + 1 ..];
            }
            return items[start..];
        }
        return items;
    }

    // First index whose key is >= `key` (lower bound).
    fn insertionIndex(self: *ObjectIndex, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.keys.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.lessThan(u8, self.keys.items[mid], key)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    fn findIndex(self: *ObjectIndex, key: []const u8) ?usize {
        const idx = self.insertionIndex(key);
        if (idx < self.keys.items.len and std.mem.eql(u8, self.keys.items[idx], key)) return idx;
        return null;
    }
};

const testing = std.testing;

fn metaFor(key: []const u8, size: u64) ObjectMeta {
    return .{
        .key = key,
        .etag = ("0" ** 32).*,
        .size = size,
        .content_type = "application/octet-stream",
        .last_modified_ms = 0,
    };
}

test "put keeps keys sorted and get returns meta" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var idx = ObjectIndex.init(arena_state.allocator());

    try idx.put(metaFor("c", 3));
    try idx.put(metaFor("a", 1));
    try idx.put(metaFor("b", 2));

    try testing.expectEqual(@as(usize, 3), idx.count());
    try testing.expectEqualStrings("a", idx.keys.items[0]);
    try testing.expectEqualStrings("b", idx.keys.items[1]);
    try testing.expectEqualStrings("c", idx.keys.items[2]);
    try testing.expectEqual(@as(u64, 2), idx.get("b").?.size);
    try testing.expectEqual(@as(u64, 6), idx.totalBytes());
}

test "put replaces existing key without duplicating" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var idx = ObjectIndex.init(arena_state.allocator());

    try idx.put(metaFor("k", 10));
    try idx.put(metaFor("k", 99));
    try testing.expectEqual(@as(usize, 1), idx.count());
    try testing.expectEqual(@as(u64, 99), idx.get("k").?.size);
}

test "remove drops key from index" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var idx = ObjectIndex.init(arena_state.allocator());

    try idx.put(metaFor("a", 1));
    try idx.put(metaFor("b", 2));
    try testing.expect(idx.remove("a"));
    try testing.expect(!idx.remove("a"));
    try testing.expectEqual(@as(usize, 1), idx.count());
    try testing.expectEqualStrings("b", idx.keys.items[0]);
}

test "rangeFrom is exclusive of the marker" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var idx = ObjectIndex.init(arena_state.allocator());

    for ([_][]const u8{ "a", "b", "c", "d" }) |k| try idx.put(metaFor(k, 1));

    const all = idx.rangeFrom(null);
    try testing.expectEqual(@as(usize, 4), all.len);

    const after_b = idx.rangeFrom("b");
    try testing.expectEqual(@as(usize, 2), after_b.len);
    try testing.expectEqualStrings("c", after_b[0]);
    try testing.expectEqualStrings("d", after_b[1]);

    // Marker between existing keys returns the next greater key.
    const after_bb = idx.rangeFrom("bb");
    try testing.expectEqual(@as(usize, 2), after_bb.len);
    try testing.expectEqualStrings("c", after_bb[0]);
}
