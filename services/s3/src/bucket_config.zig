const std = @import("std");

pub const BucketConfig = struct {
    name: []const u8,
    region: []const u8 = "us-east-1",
};

pub const Loaded = struct {
    buckets: []BucketConfig,
};

pub const LoadError = error{
    InvalidConfig,
} || std.mem.Allocator.Error || std.Io.Dir.ReadFileAllocError || std.json.ParseError(std.json.Scanner);

const max_config_bytes = 4 * 1024 * 1024;

pub fn writeDefaults(w: *std.Io.Writer) !void {
    try w.writeAll("{\n  \"buckets\": {}\n}\n");
}

pub fn loadFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!Loaded {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, std.Io.Limit.limited(max_config_bytes));
    return loadBytes(arena, bytes);
}

pub fn loadBytes(arena: std.mem.Allocator, bytes: []const u8) LoadError!Loaded {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (root != .object) {
        std.debug.print("s3 config: top-level value must be an object\n", .{});
        return LoadError.InvalidConfig;
    }

    const buckets_val = root.object.get("buckets") orelse return .{ .buckets = &.{} };
    if (buckets_val != .object) {
        std.debug.print("s3 config: 'buckets' must be an object mapping bucket names to settings\n", .{});
        return LoadError.InvalidConfig;
    }

    var list: std.ArrayListUnmanaged(BucketConfig) = .empty;
    var it = buckets_val.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (entry.value_ptr.* != .object) {
            std.debug.print("s3 config: bucket '{s}' must map to an object\n", .{name});
            return LoadError.InvalidConfig;
        }
        var region: []const u8 = "us-east-1";
        if (entry.value_ptr.*.object.get("Region")) |r| {
            if (r != .string) {
                std.debug.print("s3 config: bucket '{s}' Region must be a string\n", .{name});
                return LoadError.InvalidConfig;
            }
            region = r.string;
        }
        try list.append(arena, .{ .name = name, .region = region });
    }

    return .{ .buckets = try list.toOwnedSlice(arena) };
}

const testing = std.testing;

test "writeDefaults emits valid empty buckets object" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeDefaults(&w);
    const out = w.buffered();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const loaded = try loadBytes(arena_state.allocator(), out);
    try testing.expectEqual(@as(usize, 0), loaded.buckets.len);
}

test "loads buckets with region default and override" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = try loadBytes(arena,
        \\{ "buckets": { "logs": {}, "uploads": { "Region": "us-west-2" } } }
    );
    try testing.expectEqual(@as(usize, 2), loaded.buckets.len);
    try testing.expectEqualStrings("logs", loaded.buckets[0].name);
    try testing.expectEqualStrings("us-east-1", loaded.buckets[0].region);
    try testing.expectEqualStrings("uploads", loaded.buckets[1].name);
    try testing.expectEqualStrings("us-west-2", loaded.buckets[1].region);
}

test "non-object top level rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(LoadError.InvalidConfig, loadBytes(arena_state.allocator(), "[]"));
}

test "missing buckets key yields empty list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const loaded = try loadBytes(arena_state.allocator(), "{}");
    try testing.expectEqual(@as(usize, 0), loaded.buckets.len);
}
