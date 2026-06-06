const std = @import("std");
const atomic = @import("atomic.zig");
const object_store = @import("../store/object_store.zig");

const ObjectMeta = object_store.ObjectMeta;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema_version: u32 = 1;
pub const ReadError = error{InvalidMeta};

const max_meta_bytes = 1 * 1024 * 1024;

// Object key -> directory name. Keys can contain slashes and arbitrary bytes;
// SHA-256 hex sidesteps filename-length limits and path-traversal risk. The
// real key is preserved in meta.json for listing.
pub fn keyHashHex(key: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(key, &digest, .{});
    const alphabet = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}

pub fn objectsRoot(gpa: std.mem.Allocator, bucket_dir: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ bucket_dir, "objects" });
}

// bucket_dir/objects/<sha256(key)>; not created.
pub fn objectDir(gpa: std.mem.Allocator, bucket_dir: []const u8, key: []const u8) ![]u8 {
    const hex = keyHashHex(key);
    return std.fs.path.join(gpa, &.{ bucket_dir, "objects", &hex });
}

pub fn ensureDir(gpa: std.mem.Allocator, io: std.Io, bucket_dir: []const u8, key: []const u8) ![]u8 {
    const dir = try objectDir(gpa, bucket_dir, key);
    errdefer gpa.free(dir);
    try std.Io.Dir.createDirPath(.cwd(), io, dir);
    return dir;
}

pub fn dataPath(gpa: std.mem.Allocator, obj_dir: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ obj_dir, "data" });
}

pub fn writeData(arena: std.mem.Allocator, io: std.Io, obj_dir: []const u8, bytes: []const u8, fsync: bool) !void {
    const path = try dataPath(arena, obj_dir);
    try atomic.writeAtomic(io, path, bytes, fsync);
}

pub fn readData(arena: std.mem.Allocator, io: std.Io, obj_dir: []const u8, limit: usize) ![]u8 {
    const path = try dataPath(arena, obj_dir);
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, std.Io.Limit.limited(limit));
}

pub fn dataSize(arena: std.mem.Allocator, io: std.Io, obj_dir: []const u8) !u64 {
    const path = try dataPath(arena, obj_dir);
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    return st.size;
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c);
            },
        }
    }
    try w.writeByte('"');
}

pub fn writeMeta(arena: std.mem.Allocator, io: std.Io, obj_dir: []const u8, meta: ObjectMeta, fsync: bool) !void {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.print("{{\"schema_version\":{d},\"key\":", .{schema_version});
    try writeJsonString(w, meta.key);
    try w.writeAll(",\"etag\":");
    try writeJsonString(w, &meta.etag);
    try w.print(",\"multipart_part_count\":{d},\"size\":{d},\"content_type\":", .{ meta.multipart_part_count, meta.size });
    try writeJsonString(w, meta.content_type);
    try w.writeAll(",\"storage_class\":");
    try writeJsonString(w, meta.storage_class);
    try w.print(",\"last_modified_ms\":{d},\"user_meta\":{{", .{meta.last_modified_ms});
    var it = meta.user_meta.iterator();
    var first = true;
    while (it.next()) |e| {
        if (!first) try w.writeByte(',');
        first = false;
        try writeJsonString(w, e.key_ptr.*);
        try w.writeByte(':');
        try writeJsonString(w, e.value_ptr.*);
    }
    try w.writeAll("}}");

    const path = try std.fs.path.join(arena, &.{ obj_dir, "meta.json" });
    try atomic.writeAtomic(io, path, aw.written(), fsync);
}

pub fn readMeta(arena: std.mem.Allocator, io: std.Io, obj_dir: []const u8) !ObjectMeta {
    const path = try std.fs.path.join(arena, &.{ obj_dir, "meta.json" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, std.Io.Limit.limited(max_meta_bytes));
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (root != .object) return ReadError.InvalidMeta;
    const obj = root.object;

    const key_v = obj.get("key") orelse return ReadError.InvalidMeta;
    const etag_v = obj.get("etag") orelse return ReadError.InvalidMeta;
    if (key_v != .string or etag_v != .string) return ReadError.InvalidMeta;
    if (etag_v.string.len != 32) return ReadError.InvalidMeta;

    var etag: [32]u8 = undefined;
    @memcpy(&etag, etag_v.string[0..32]);

    var meta: ObjectMeta = .{
        .key = try arena.dupe(u8, key_v.string),
        .etag = etag,
        .size = uintField(obj, "size"),
        .content_type = "application/octet-stream",
        .last_modified_ms = intField(obj, "last_modified_ms"),
    };
    meta.multipart_part_count = @intCast(uintField(obj, "multipart_part_count"));

    if (obj.get("content_type")) |c| {
        if (c == .string) meta.content_type = try arena.dupe(u8, c.string);
    }
    if (obj.get("storage_class")) |c| {
        if (c == .string) meta.storage_class = try arena.dupe(u8, c.string);
    }
    if (obj.get("user_meta")) |um| {
        if (um != .object) return ReadError.InvalidMeta;
        var it = um.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .string) return ReadError.InvalidMeta;
            try meta.user_meta.put(arena, try arena.dupe(u8, e.key_ptr.*), try arena.dupe(u8, e.value_ptr.*.string));
        }
    }
    return meta;
}

fn uintField(obj: std.json.ObjectMap, key: []const u8) u64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |n| if (n < 0) 0 else @intCast(n),
        else => 0,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |n| n,
        else => 0,
    };
}

// deleteTree treats a missing path as success, so callers get idempotent removal.
pub fn remove(io: std.Io, obj_dir: []const u8) !void {
    try std.Io.Dir.cwd().deleteTree(io, obj_dir);
}

const testing = std.testing;

test "keyHashHex is deterministic 64 hex chars" {
    const a = keyHashHex("logs/2026/06/06.txt");
    const b = keyHashHex("logs/2026/06/06.txt");
    try testing.expectEqualSlices(u8, &a, &b);
    for (a) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(ok);
    }
    try testing.expect(!std.mem.eql(u8, &a, &keyHashHex("other")));
}

test "data + meta round-trip with user metadata and multipart count" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bucket_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const key = "logs/a b/c.txt";
    const dir = try ensureDir(arena, io, bucket_dir, key);

    try writeData(arena, io, dir, "hello world", false);

    var um: object_store.UserMeta = .empty;
    try um.put(arena, "foo", "bar");
    const meta: ObjectMeta = .{
        .key = key,
        .etag = ("a" ** 32).*,
        .multipart_part_count = 3,
        .size = 11,
        .content_type = "text/plain",
        .user_meta = um,
        .last_modified_ms = 1717689600000,
    };
    try writeMeta(arena, io, dir, meta, false);

    const data = try readData(arena, io, dir, 1024);
    try testing.expectEqualStrings("hello world", data);
    try testing.expectEqual(@as(u64, 11), try dataSize(arena, io, dir));

    const got = try readMeta(arena, io, dir);
    try testing.expectEqualStrings(key, got.key);
    try testing.expectEqualSlices(u8, &meta.etag, &got.etag);
    try testing.expectEqual(@as(u16, 3), got.multipart_part_count);
    try testing.expectEqual(@as(u64, 11), got.size);
    try testing.expectEqualStrings("text/plain", got.content_type);
    try testing.expectEqualStrings("bar", got.user_meta.get("foo").?);
}

test "remove deletes the object dir" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bucket_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dir = try ensureDir(arena, io, bucket_dir, "k");
    try writeData(arena, io, dir, "x", false);
    try remove(io, dir);
    try testing.expectError(error.FileNotFound, dataSize(arena, io, dir));
    // Idempotent.
    try remove(io, dir);
}
