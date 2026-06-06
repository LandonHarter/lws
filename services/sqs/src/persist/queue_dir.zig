const std = @import("std");
const config = @import("config");
const attrs = @import("../attrs.zig");
const json_proto = @import("../wire/json_proto.zig");

pub const AttrMap = std.StringArrayHashMapUnmanaged(config.Value);
pub const TagMap = std.StringArrayHashMapUnmanaged([]const u8);

pub const schema_version: u32 = 1;

pub const Meta = struct {
    queue_id: [16]u8,
    name: []const u8,
    kind: config.QueueKind,
    attributes: AttrMap,
    tags: TagMap,
    created_at: i64,
    last_modified_at: i64,
};

pub const ReadError = error{InvalidMeta};

const max_meta_bytes = 1 * 1024 * 1024;

pub fn idHex(id: [16]u8) [32]u8 {
    const hex = "0123456789abcdef";
    var out: [32]u8 = undefined;
    for (id, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

fn parseIdHex(s: []const u8) ?[16]u8 {
    if (s.len != 32) return null;
    var out: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const hi = std.fmt.charToDigit(s[i * 2], 16) catch return null;
        const lo = std.fmt.charToDigit(s[i * 2 + 1], 16) catch return null;
        out[i] = (hi << 4) | lo;
    }
    return out;
}

// data_dir/queues/<hex>; not created. Returns the path in `gpa`.
pub fn dirPath(gpa: std.mem.Allocator, data_dir: []const u8, queue_id: [16]u8) ![]u8 {
    const hex = idHex(queue_id);
    return std.fs.path.join(gpa, &.{ data_dir, "queues", &hex });
}

// data_dir/queues/<hex>; created if absent. Returns the path in `gpa`.
pub fn ensureDir(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, queue_id: [16]u8) ![]u8 {
    const path = try dirPath(gpa, data_dir, queue_id);
    errdefer gpa.free(path);
    try std.Io.Dir.createDirPath(.cwd(), io, path);
    return path;
}

pub fn queuesRoot(gpa: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ data_dir, "queues" });
}

fn writeFileSync(io: std.Io, path: []const u8, bytes: []const u8, fsync: bool) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    if (fsync) try file.sync(io);
}

fn valueToRaw(arena: std.mem.Allocator, v: config.Value) ![]const u8 {
    return switch (v) {
        .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .boolean => |b| if (b) "true" else "false",
        .string => |s| s,
        .json => |j| j,
    };
}

pub fn writeMeta(arena: std.mem.Allocator, io: std.Io, dir: []const u8, meta: Meta, fsync: bool) !void {
    var w = json_proto.Writer.init(arena);
    try w.beginObject();

    try w.writeKey("schema_version");
    try w.writeInt(@intCast(schema_version));
    try w.writeKey("queue_id");
    const hex = idHex(meta.queue_id);
    try w.writeString(&hex);
    try w.writeKey("name");
    try w.writeString(meta.name);
    try w.writeKey("kind");
    try w.writeString(@tagName(meta.kind));
    try w.writeKey("created_at");
    try w.writeInt(meta.created_at);
    try w.writeKey("last_modified_at");
    try w.writeInt(meta.last_modified_at);

    try w.writeKey("attributes");
    try w.beginObject();
    var ait = meta.attributes.iterator();
    while (ait.next()) |e| {
        try w.writeKey(e.key_ptr.*);
        try w.writeString(try valueToRaw(arena, e.value_ptr.*));
    }
    try w.endObject();

    try w.writeKey("tags");
    try w.beginObject();
    var tit = meta.tags.iterator();
    while (tit.next()) |e| {
        try w.writeKey(e.key_ptr.*);
        try w.writeString(e.value_ptr.*);
    }
    try w.endObject();

    try w.endObject();

    const path = try std.fs.path.join(arena, &.{ dir, "meta.json" });
    try writeFileSync(io, path, w.finish(), fsync);
}

pub fn readMeta(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !Meta {
    const path = try std.fs.path.join(arena, &.{ dir, "meta.json" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, std.Io.Limit.limited(max_meta_bytes));
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (root != .object) return ReadError.InvalidMeta;
    const obj = root.object;

    const name_v = obj.get("name") orelse return ReadError.InvalidMeta;
    const kind_v = obj.get("kind") orelse return ReadError.InvalidMeta;
    const id_v = obj.get("queue_id") orelse return ReadError.InvalidMeta;
    if (name_v != .string or kind_v != .string or id_v != .string) return ReadError.InvalidMeta;

    const kind: config.QueueKind = if (std.mem.eql(u8, kind_v.string, "fifo")) .fifo else .standard;
    const queue_id = parseIdHex(id_v.string) orelse return ReadError.InvalidMeta;

    var attributes: AttrMap = .empty;
    if (obj.get("attributes")) |a| {
        if (a != .object) return ReadError.InvalidMeta;
        var it = a.object.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const val = e.value_ptr.*;
            if (val != .string) return ReadError.InvalidMeta;
            const resolved = config.validateOne(&attrs.queue_attrs, .create, kind, key, val.string) catch return ReadError.InvalidMeta;
            try attributes.put(arena, try arena.dupe(u8, key), resolved);
        }
    }

    var tags: TagMap = .empty;
    if (obj.get("tags")) |t| {
        if (t != .object) return ReadError.InvalidMeta;
        var it = t.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .string) return ReadError.InvalidMeta;
            try tags.put(arena, try arena.dupe(u8, e.key_ptr.*), try arena.dupe(u8, e.value_ptr.*.string));
        }
    }

    return .{
        .queue_id = queue_id,
        .name = try arena.dupe(u8, name_v.string),
        .kind = kind,
        .attributes = attributes,
        .tags = tags,
        .created_at = intField(obj, "created_at"),
        .last_modified_at = intField(obj, "last_modified_at"),
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |n| n,
        else => 0,
    };
}

pub fn markDeleted(arena: std.mem.Allocator, io: std.Io, dir: []const u8, deleted_at: i64, fsync: bool) !void {
    const path = try std.fs.path.join(arena, &.{ dir, "deleted_at" });
    const body = try std.fmt.allocPrint(arena, "{d}", .{deleted_at});
    try writeFileSync(io, path, body, fsync);
}

pub fn readDeleted(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !?i64 {
    const path = try std.fs.path.join(arena, &.{ dir, "deleted_at" });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, std.Io.Limit.limited(64)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, bytes, " \n\r\t");
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

const testing = std.testing;

test "idHex round-trips" {
    const id = [16]u8{ 0, 1, 2, 15, 16, 255, 100, 7, 8, 9, 10, 11, 12, 13, 14, 200 };
    const hex = idHex(id);
    const back = parseIdHex(&hex).?;
    try testing.expectEqualSlices(u8, &id, &back);
}

test "writeMeta then readMeta round-trips typed attrs" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dir = try ensureDir(arena, io, data_dir, .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });

    var attributes: AttrMap = .empty;
    try attributes.put(arena, "VisibilityTimeout", .{ .integer = 60 });
    try attributes.put(arena, "SqsManagedSseEnabled", .{ .boolean = true });
    try attributes.put(arena, "RedrivePolicy", .{ .json = "{\"maxReceiveCount\":5}" });
    var tags: TagMap = .empty;
    try tags.put(arena, "env", "dev");

    const meta: Meta = .{
        .queue_id = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },
        .name = "t",
        .kind = .standard,
        .attributes = attributes,
        .tags = tags,
        .created_at = 1000,
        .last_modified_at = 2000,
    };
    try writeMeta(arena, io, dir, meta, false);

    const got = try readMeta(arena, io, dir);
    try testing.expectEqualStrings("t", got.name);
    try testing.expectEqual(config.QueueKind.standard, got.kind);
    try testing.expectEqual(@as(i64, 60), got.attributes.get("VisibilityTimeout").?.integer);
    try testing.expect(got.attributes.get("SqsManagedSseEnabled").?.boolean);
    try testing.expectEqualStrings("{\"maxReceiveCount\":5}", got.attributes.get("RedrivePolicy").?.json);
    try testing.expectEqualStrings("dev", got.tags.get("env").?);
    try testing.expectEqual(@as(i64, 1000), got.created_at);
    try testing.expectEqual(@as(i64, 2000), got.last_modified_at);
}

test "markDeleted then readDeleted" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dir = try ensureDir(arena, io, data_dir, .{ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9 });
    try testing.expect((try readDeleted(arena, io, dir)) == null);
    try markDeleted(arena, io, dir, 12345, false);
    try testing.expectEqual(@as(i64, 12345), (try readDeleted(arena, io, dir)).?);
}
