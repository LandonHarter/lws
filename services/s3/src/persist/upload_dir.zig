const std = @import("std");
const atomic = @import("atomic.zig");
const multipart = @import("../store/multipart.zig");
const object_store = @import("../store/object_store.zig");

const PartMeta = multipart.PartMeta;

pub const schema_version: u32 = 1;
pub const ReadError = error{InvalidMeta};

const max_meta_bytes = 4 * 1024 * 1024;
const copy_buf_size = 64 * 1024;

pub const ParsedMeta = struct {
    upload_id: [36]u8,
    key: []const u8,
    content_type: []const u8,
    initiated_at_ms: i64,
    user_meta: object_store.UserMeta = .empty,
    parts: []PartMeta,
};

pub fn uploadsRoot(gpa: std.mem.Allocator, bucket_dir: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ bucket_dir, "uploads" });
}

pub fn uploadDir(gpa: std.mem.Allocator, bucket_dir: []const u8, upload_id: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ bucket_dir, "uploads", upload_id });
}

// Creates uploads/<id>/parts/; returns the upload base dir.
pub fn ensureDir(gpa: std.mem.Allocator, io: std.Io, bucket_dir: []const u8, upload_id: []const u8) ![]u8 {
    const base = try uploadDir(gpa, bucket_dir, upload_id);
    errdefer gpa.free(base);
    const parts = try std.fs.path.join(gpa, &.{ base, "parts" });
    defer gpa.free(parts);
    try std.Io.Dir.createDirPath(.cwd(), io, parts);
    return base;
}

pub fn partPath(gpa: std.mem.Allocator, upload_base: []const u8, n: u16) ![]u8 {
    var nbuf: [8]u8 = undefined;
    const ns = std.fmt.bufPrint(&nbuf, "{d}", .{n}) catch unreachable;
    return std.fs.path.join(gpa, &.{ upload_base, "parts", ns });
}

pub fn writePart(arena: std.mem.Allocator, io: std.Io, upload_base: []const u8, n: u16, bytes: []const u8, fsync: bool) !void {
    const path = try partPath(arena, upload_base, n);
    try atomic.writeAtomic(io, path, bytes, fsync);
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

pub fn writeMeta(arena: std.mem.Allocator, io: std.Io, upload_base: []const u8, u: *const multipart.Upload, fsync: bool) !void {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.print("{{\"schema_version\":{d},\"upload_id\":", .{schema_version});
    try writeJsonString(w, u.idSlice());
    try w.writeAll(",\"key\":");
    try writeJsonString(w, u.key);
    try w.writeAll(",\"content_type\":");
    try writeJsonString(w, u.content_type);
    try w.print(",\"initiated_at_ms\":{d},\"user_meta\":{{", .{u.initiated_at_ms});
    var umit = u.user_meta.iterator();
    var first = true;
    while (umit.next()) |e| {
        if (!first) try w.writeByte(',');
        first = false;
        try writeJsonString(w, e.key_ptr.*);
        try w.writeByte(':');
        try writeJsonString(w, e.value_ptr.*);
    }
    try w.writeAll("},\"parts\":[");
    for (u.parts.items, 0..) |p, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"n\":{d},\"etag\":", .{p.n});
        try writeJsonString(w, &p.etag);
        try w.print(",\"size\":{d}}}", .{p.size});
    }
    try w.writeAll("]}");

    const path = try std.fs.path.join(arena, &.{ upload_base, "meta.json" });
    try atomic.writeAtomic(io, path, aw.written(), fsync);
}

pub fn readMeta(arena: std.mem.Allocator, io: std.Io, upload_base: []const u8) !ParsedMeta {
    const path = try std.fs.path.join(arena, &.{ upload_base, "meta.json" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, std.Io.Limit.limited(max_meta_bytes));
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (root != .object) return ReadError.InvalidMeta;
    const obj = root.object;

    const id_v = obj.get("upload_id") orelse return ReadError.InvalidMeta;
    const key_v = obj.get("key") orelse return ReadError.InvalidMeta;
    if (id_v != .string or key_v != .string) return ReadError.InvalidMeta;
    if (id_v.string.len != 36) return ReadError.InvalidMeta;

    var upload_id: [36]u8 = undefined;
    @memcpy(&upload_id, id_v.string[0..36]);

    var content_type: []const u8 = "application/octet-stream";
    if (obj.get("content_type")) |c| {
        if (c == .string) content_type = try arena.dupe(u8, c.string);
    }

    var initiated_at_ms: i64 = 0;
    if (obj.get("initiated_at_ms")) |c| {
        if (c == .integer) initiated_at_ms = c.integer;
    }

    var user_meta: object_store.UserMeta = .empty;
    if (obj.get("user_meta")) |um| {
        if (um != .object) return ReadError.InvalidMeta;
        var it = um.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .string) return ReadError.InvalidMeta;
            try user_meta.put(arena, try arena.dupe(u8, e.key_ptr.*), try arena.dupe(u8, e.value_ptr.*.string));
        }
    }

    var parts: std.ArrayList(PartMeta) = .empty;
    if (obj.get("parts")) |pv| {
        if (pv != .array) return ReadError.InvalidMeta;
        for (pv.array.items) |item| {
            if (item != .object) return ReadError.InvalidMeta;
            const po = item.object;
            const n_v = po.get("n") orelse return ReadError.InvalidMeta;
            const etag_v = po.get("etag") orelse return ReadError.InvalidMeta;
            if (n_v != .integer or etag_v != .string or etag_v.string.len != 32) return ReadError.InvalidMeta;
            var etag: [32]u8 = undefined;
            @memcpy(&etag, etag_v.string[0..32]);
            const size_v = po.get("size");
            const size: u64 = if (size_v) |s| (if (s == .integer and s.integer >= 0) @intCast(s.integer) else 0) else 0;
            try parts.append(arena, .{ .n = @intCast(n_v.integer), .etag = etag, .size = size });
        }
    }

    return .{
        .upload_id = upload_id,
        .key = try arena.dupe(u8, key_v.string),
        .content_type = content_type,
        .initiated_at_ms = initiated_at_ms,
        .user_meta = user_meta,
        .parts = try parts.toOwnedSlice(arena),
    };
}

// Concatenates the listed parts (in slice order) into `dest_path`, written
// atomically via a tmp file. Streams through a fixed 64 KiB buffer so full
// parts are never held in memory. Returns the assembled byte length.
pub fn assemble(arena: std.mem.Allocator, io: std.Io, upload_base: []const u8, dest_path: []const u8, parts: []const PartMeta, fsync: bool) !u64 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&pbuf, "{s}.tmp", .{dest_path});

    var dest = try std.Io.Dir.cwd().createFile(io, tmp, .{});
    var dest_off: u64 = 0;
    {
        errdefer dest.close(io);
        var copy_buf: [copy_buf_size]u8 = undefined;
        for (parts) |p| {
            const pp = try partPath(arena, upload_base, p.n);
            var src = try std.Io.Dir.cwd().openFile(io, pp, .{});
            defer src.close(io);
            var src_off: u64 = 0;
            while (true) {
                const n = try src.readPositionalAll(io, &copy_buf, src_off);
                if (n == 0) break;
                try dest.writePositionalAll(io, copy_buf[0..n], dest_off);
                dest_off += n;
                src_off += n;
                if (n < copy_buf.len) break;
            }
        }
        if (fsync) try dest.sync(io);
    }
    dest.close(io);
    try std.Io.Dir.cwd().rename(tmp, .cwd(), dest_path, io);
    return dest_off;
}

// deleteTree treats a missing path as success, so abort/cleanup is idempotent.
pub fn remove(io: std.Io, upload_base: []const u8) !void {
    try std.Io.Dir.cwd().deleteTree(io, upload_base);
}

const testing = std.testing;
const Md5 = std.crypto.hash.Md5;

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

test "part write + meta round-trip + assemble" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bucket_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const id = "8fd13a1c-7c8e-4f1e-8e3a-99b4f2e0a1d2";
    const base = try ensureDir(arena, io, bucket_dir, id);

    const p1 = "AAAAA";
    const p2 = "BBBBBBBBBB";
    try writePart(arena, io, base, 1, p1, false);
    try writePart(arena, io, base, 2, p2, false);

    // Build an Upload to persist its meta.
    var index = multipart.UploadIndex.init(testing.allocator);
    defer index.deinit();
    var uid: [36]u8 = undefined;
    @memcpy(&uid, id);
    const u = try index.create(uid, "big", "application/octet-stream", 1717689600000);
    try u.putUserMeta("foo", "bar");
    try u.putPart(.{ .n = 1, .etag = md5Hex(p1), .size = p1.len });
    try u.putPart(.{ .n = 2, .etag = md5Hex(p2), .size = p2.len });
    try writeMeta(arena, io, base, u, false);

    const parsed = try readMeta(arena, io, base);
    try testing.expectEqualStrings("big", parsed.key);
    try testing.expectEqualSlices(u8, id, &parsed.upload_id);
    try testing.expectEqual(@as(usize, 2), parsed.parts.len);
    try testing.expectEqual(@as(u16, 1), parsed.parts[0].n);
    try testing.expectEqualStrings("bar", parsed.user_meta.get("foo").?);

    const dest = try std.fs.path.join(arena, &.{ bucket_dir, "assembled" });
    const total = try assemble(arena, io, base, dest, parsed.parts, false);
    try testing.expectEqual(@as(u64, p1.len + p2.len), total);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, dest, arena, std.Io.Limit.limited(1024));
    try testing.expectEqualStrings(p1 ++ p2, got);

    try remove(io, base);
    const pp = try partPath(arena, base, 1);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, pp, .{}));
}
