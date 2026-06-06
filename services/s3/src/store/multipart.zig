const std = @import("std");
const object_store = @import("object_store.zig");

const Md5 = std.crypto.hash.Md5;

pub const PartMeta = struct {
    n: u16, // 1..10000
    etag: [32]u8, // lowercase md5 hex of the part body
    size: u64,
};

// One in-flight multipart upload. Owns its own arena (allocated from the
// registry gpa) so AbortMultipartUpload / CompleteMultipartUpload can reclaim
// it in one shot without touching the bucket arena.
pub const Upload = struct {
    arena: *std.heap.ArenaAllocator,
    upload_id: [36]u8, // UUIDv4 hex with dashes
    key: []const u8,
    content_type: []const u8,
    user_meta: object_store.UserMeta = .empty,
    initiated_at_ms: i64,
    parts: std.ArrayList(PartMeta) = .empty,

    pub fn idSlice(self: *const Upload) []const u8 {
        return self.upload_id[0..];
    }

    // Insert or replace the part numbered `pm.n`, keeping `parts` sorted by n.
    pub fn putPart(self: *Upload, pm: PartMeta) !void {
        const a = self.arena.allocator();
        var i: usize = 0;
        while (i < self.parts.items.len and self.parts.items[i].n < pm.n) : (i += 1) {}
        if (i < self.parts.items.len and self.parts.items[i].n == pm.n) {
            self.parts.items[i] = pm;
            return;
        }
        try self.parts.insert(a, i, pm);
    }

    pub fn putUserMeta(self: *Upload, key: []const u8, value: []const u8) !void {
        const a = self.arena.allocator();
        try self.user_meta.put(a, try a.dupe(u8, key), try a.dupe(u8, value));
    }
};

pub const UploadIndex = struct {
    gpa: std.mem.Allocator,
    by_id: std.StringArrayHashMapUnmanaged(*Upload) = .empty,

    pub fn init(gpa: std.mem.Allocator) UploadIndex {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *UploadIndex) void {
        for (self.by_id.values()) |u| destroy(self.gpa, u);
        self.by_id.deinit(self.gpa);
    }

    fn destroy(gpa: std.mem.Allocator, u: *Upload) void {
        const arena_ptr = u.arena;
        arena_ptr.deinit();
        gpa.destroy(arena_ptr);
    }

    // Allocates an Upload (with its own arena) and registers it. `key` and
    // `content_type` are duped into the upload arena.
    pub fn create(
        self: *UploadIndex,
        upload_id: [36]u8,
        key: []const u8,
        content_type: []const u8,
        initiated_at_ms: i64,
    ) !*Upload {
        const arena_ptr = try self.gpa.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.gpa);
        var keep = false;
        defer if (!keep) {
            arena_ptr.deinit();
            self.gpa.destroy(arena_ptr);
        };
        const a = arena_ptr.allocator();

        const u = try a.create(Upload);
        u.* = .{
            .arena = arena_ptr,
            .upload_id = upload_id,
            .key = try a.dupe(u8, key),
            .content_type = try a.dupe(u8, content_type),
            .initiated_at_ms = initiated_at_ms,
        };
        try self.by_id.put(self.gpa, u.idSlice(), u);
        keep = true;
        return u;
    }

    pub fn get(self: *UploadIndex, upload_id: []const u8) ?*Upload {
        return self.by_id.get(upload_id);
    }

    pub fn remove(self: *UploadIndex, upload_id: []const u8) bool {
        const idx = self.by_id.getIndex(upload_id) orelse return false;
        const u = self.by_id.values()[idx];
        self.by_id.orderedRemoveAt(idx);
        destroy(self.gpa, u);
        return true;
    }

    pub fn count(self: *const UploadIndex) usize {
        return self.by_id.count();
    }

    // Uploads sorted by key then upload-id, duped pointer slice into `out`.
    pub fn list(self: *UploadIndex, out: std.mem.Allocator) ![]const *Upload {
        const slice = try out.alloc(*Upload, self.by_id.count());
        @memcpy(slice, self.by_id.values());
        std.mem.sort(*Upload, slice, {}, lessThanUpload);
        return slice;
    }

    fn lessThanUpload(_: void, a: *Upload, b: *Upload) bool {
        const ko = std.mem.order(u8, a.key, b.key);
        if (ko != .eq) return ko == .lt;
        return std.mem.lessThan(u8, a.idSlice(), b.idSlice());
    }
};

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexToRaw16(hex: [32]u8) ?[16]u8 {
    var out: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const hi = hexNibble(hex[i * 2]) orelse return null;
        const lo = hexNibble(hex[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return out;
}

// S3 multipart ETag: md5( concat( raw_md5(part_i) ) ) rendered as lowercase
// hex, suffixed with "-<part-count>". Each part's stored etag is its md5 hex,
// converted back to its 16 raw bytes before hashing. Result is allocated in
// `arena`. Returns error.InvalidPartEtag if any part etag is not valid hex.
pub fn computeMultipartEtag(arena: std.mem.Allocator, parts: []const PartMeta) ![]const u8 {
    var h = Md5.init(.{});
    for (parts) |p| {
        const raw = hexToRaw16(p.etag) orelse return error.InvalidPartEtag;
        h.update(&raw);
    }
    var digest: [16]u8 = undefined;
    h.final(&digest);

    const alphabet = "0123456789abcdef";
    var hex: [32]u8 = undefined;
    for (digest, 0..) |b, i| {
        hex[i * 2] = alphabet[b >> 4];
        hex[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return std.fmt.allocPrint(arena, "{s}-{d}", .{ hex, parts.len });
}

const testing = std.testing;

fn md5Hex(bytes: []const u8) [32]u8 {
    var raw: [16]u8 = undefined;
    Md5.hash(bytes, &raw, .{});
    const alphabet = "0123456789abcdef";
    var out: [32]u8 = undefined;
    for (raw, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}

test "computeMultipartEtag matches md5(concat(raw md5s)) + -N" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]PartMeta{
        .{ .n = 1, .etag = md5Hex("part-one"), .size = 8 },
        .{ .n = 2, .etag = md5Hex("part-two"), .size = 8 },
        .{ .n = 3, .etag = md5Hex("part-three"), .size = 10 },
    };

    // Independently compute expected.
    var h = Md5.init(.{});
    for (parts) |p| {
        var raw: [16]u8 = undefined;
        Md5.hash(switch (p.n) {
            1 => "part-one",
            2 => "part-two",
            else => "part-three",
        }, &raw, .{});
        h.update(&raw);
    }
    var digest: [16]u8 = undefined;
    h.final(&digest);
    const alphabet = "0123456789abcdef";
    var hex: [32]u8 = undefined;
    for (digest, 0..) |b, i| {
        hex[i * 2] = alphabet[b >> 4];
        hex[i * 2 + 1] = alphabet[b & 0x0f];
    }
    const expected = try std.fmt.allocPrint(arena, "{s}-3", .{hex});

    const got = try computeMultipartEtag(arena, &parts);
    try testing.expectEqualStrings(expected, got);
}

test "create, get, putPart sorted, remove" {
    var index = UploadIndex.init(testing.allocator);
    defer index.deinit();

    const id = ("a" ** 36).*;
    const u = try index.create(id, "big", "application/octet-stream", 1000);
    try testing.expect(index.get(&id) != null);

    try u.putPart(.{ .n = 2, .etag = md5Hex("b"), .size = 5 });
    try u.putPart(.{ .n = 1, .etag = md5Hex("a"), .size = 5 });
    try testing.expectEqual(@as(u16, 1), u.parts.items[0].n);
    try testing.expectEqual(@as(u16, 2), u.parts.items[1].n);

    // Replace part 1.
    try u.putPart(.{ .n = 1, .etag = md5Hex("aa"), .size = 6 });
    try testing.expectEqual(@as(usize, 2), u.parts.items.len);
    try testing.expectEqual(@as(u64, 6), u.parts.items[0].size);

    try testing.expect(index.remove(&id));
    try testing.expect(!index.remove(&id));
    try testing.expectEqual(@as(usize, 0), index.count());
}
