const std = @import("std");
const atomic = @import("atomic.zig");

pub const schema_version: u32 = 1;

pub const Meta = struct {
    name: []const u8,
    region: []const u8 = "us-east-1",
    created_at: i64,
};

pub const ReadError = error{InvalidMeta};

pub const NameError = error{InvalidBucketName};

const max_meta_bytes = 1 * 1024 * 1024;

// DNS-1123-style label check so a bucket name can double as a directory name
// without escaping: 3-63 chars, lowercase letters/digits/hyphens/dots, first
// and last char alphanumeric, no consecutive dots.
pub fn validateName(name: []const u8) NameError!void {
    if (name.len < 3 or name.len > 63) return NameError.InvalidBucketName;
    for (name, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '.';
        if (!ok) return NameError.InvalidBucketName;
        if (i + 1 < name.len and c == '.' and name[i + 1] == '.') return NameError.InvalidBucketName;
    }
    if (!isAlnum(name[0]) or !isAlnum(name[name.len - 1])) return NameError.InvalidBucketName;
}

fn isAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

pub fn bucketsRoot(gpa: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ data_dir, "buckets" });
}

// data_dir/buckets/<name>; not created.
pub fn dirPath(gpa: std.mem.Allocator, data_dir: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ data_dir, "buckets", name });
}

// Creates buckets/<name>/{objects,uploads}; returns the bucket base dir path.
pub fn ensureDirs(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, name: []const u8) ![]u8 {
    const base = try dirPath(gpa, data_dir, name);
    errdefer gpa.free(base);
    const objects = try std.fs.path.join(gpa, &.{ base, "objects" });
    defer gpa.free(objects);
    const uploads = try std.fs.path.join(gpa, &.{ base, "uploads" });
    defer gpa.free(uploads);
    try std.Io.Dir.createDirPath(.cwd(), io, objects);
    try std.Io.Dir.createDirPath(.cwd(), io, uploads);
    return base;
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
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

pub fn writeMeta(arena: std.mem.Allocator, io: std.Io, dir: []const u8, meta: Meta, fsync: bool) !void {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.print("{{\"schema_version\":{d},\"name\":", .{schema_version});
    try writeJsonString(w, meta.name);
    try w.writeAll(",\"region\":");
    try writeJsonString(w, meta.region);
    try w.print(",\"created_at\":{d}}}", .{meta.created_at});

    const path = try std.fs.path.join(arena, &.{ dir, "meta.json" });
    try atomic.writeAtomic(io, path, aw.written(), fsync);
}

pub fn readMeta(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !Meta {
    const path = try std.fs.path.join(arena, &.{ dir, "meta.json" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, std.Io.Limit.limited(max_meta_bytes));
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (root != .object) return ReadError.InvalidMeta;
    const obj = root.object;

    const name_v = obj.get("name") orelse return ReadError.InvalidMeta;
    if (name_v != .string) return ReadError.InvalidMeta;

    var region: []const u8 = "us-east-1";
    if (obj.get("region")) |r| {
        if (r != .string) return ReadError.InvalidMeta;
        region = try arena.dupe(u8, r.string);
    }

    var created_at: i64 = 0;
    if (obj.get("created_at")) |c| {
        if (c == .integer) created_at = c.integer;
    }

    return .{
        .name = try arena.dupe(u8, name_v.string),
        .region = region,
        .created_at = created_at,
    };
}

const testing = std.testing;

test "validateName accepts valid DNS labels" {
    try validateName("abc");
    try validateName("test-bucket");
    try validateName("my.bucket.name");
    try validateName("a12");
    try validateName("logs2026");
}

test "validateName rejects illegal names" {
    try testing.expectError(NameError.InvalidBucketName, validateName("ab")); // too short
    try testing.expectError(NameError.InvalidBucketName, validateName("a" ** 64)); // too long
    try testing.expectError(NameError.InvalidBucketName, validateName("UpperCase"));
    try testing.expectError(NameError.InvalidBucketName, validateName("under_score"));
    try testing.expectError(NameError.InvalidBucketName, validateName("-leading"));
    try testing.expectError(NameError.InvalidBucketName, validateName("trailing-"));
    try testing.expectError(NameError.InvalidBucketName, validateName("double..dot"));
    try testing.expectError(NameError.InvalidBucketName, validateName(".dotlead"));
}

test "writeMeta then readMeta round-trips" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dir = try ensureDirs(arena, io, data_dir, "test-bucket");
    try writeMeta(arena, io, dir, .{ .name = "test-bucket", .region = "us-west-2", .created_at = 1717689600 }, false);

    const got = try readMeta(arena, io, dir);
    try testing.expectEqualStrings("test-bucket", got.name);
    try testing.expectEqualStrings("us-west-2", got.region);
    try testing.expectEqual(@as(i64, 1717689600), got.created_at);
}
