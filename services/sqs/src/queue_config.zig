const std = @import("std");
const config = @import("config");
const attrs = @import("attrs.zig");

pub const QueueConfig = struct {
    kind: config.QueueKind,
    attributes: std.StringArrayHashMapUnmanaged(config.Value),
};

pub const LoadError = error{
    InvalidConfig,
} || config.Error || std.mem.Allocator.Error || std.Io.Dir.ReadFileAllocError || std.json.ParseError(std.json.Scanner);

const max_config_bytes = 4 * 1024 * 1024;

pub fn writeDefaults(kind: config.QueueKind, w: *std.Io.Writer) !void {
    try config.writeDefaults(&attrs.queue_attrs, kind, w);
}

pub fn loadFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!QueueConfig {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, std.Io.Limit.limited(max_config_bytes));
    return loadBytes(arena, bytes);
}

pub fn loadBytes(arena: std.mem.Allocator, bytes: []const u8) LoadError!QueueConfig {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (root != .object) {
        std.debug.print("sqs config: top-level value must be an object of attributes\n", .{});
        return LoadError.InvalidConfig;
    }
    const obj = root.object;

    const kind: config.QueueKind = blk: {
        if (obj.get("FifoQueue")) |fq| {
            if (fq == .string and std.mem.eql(u8, fq.string, "true")) break :blk .fifo;
        }
        break :blk .standard;
    };

    var map: std.StringArrayHashMapUnmanaged(config.Value) = .empty;
    for (attrs.queue_attrs) |spec| {
        const applies_ok = switch (spec.applies) {
            .all => true,
            .fifo_only => kind == .fifo,
            .standard_only => kind == .standard,
        };
        if (spec.mutability == .read_only) continue;
        if (!applies_ok) continue;
        if (spec.default) |d| try map.put(arena, spec.name, d);
    }

    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (val != .string) {
            std.debug.print("sqs config: attribute '{s}' value must be a string\n", .{key});
            return config.Error.InvalidAttributeValue;
        }
        const resolved = config.validateOne(&attrs.queue_attrs, .create, kind, key, val.string) catch |err| {
            std.debug.print("sqs config: attribute '{s}'={s} rejected: {s}\n", .{ key, val.string, @errorName(err) });
            return err;
        };
        try map.put(arena, key, resolved);
    }

    return .{ .kind = kind, .attributes = map };
}

const testing = std.testing;

test "loads flat attribute config" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const q = try loadBytes(arena, "{ \"FifoQueue\": \"true\", \"VisibilityTimeout\": \"60\", \"ContentBasedDeduplication\": \"true\" }");
    try testing.expectEqual(config.QueueKind.fifo, q.kind);
    try testing.expectEqual(@as(i64, 60), q.attributes.get("VisibilityTimeout").?.integer);
    try testing.expect(q.attributes.get("ContentBasedDeduplication").?.boolean);
}

test "defaults applied for unset attributes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const q = try loadBytes(arena, "{}");
    try testing.expectEqual(config.QueueKind.standard, q.kind);
    try testing.expectEqual(@as(i64, 30), q.attributes.get("VisibilityTimeout").?.integer);
}

test "standard queue omits fifo-only defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const q = try loadBytes(arena, "{}");
    try testing.expect(q.attributes.get("DeduplicationScope") == null);
}

test "fifo config gets fifo-only defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const q = try loadBytes(arena, "{ \"FifoQueue\": \"true\" }");
    try testing.expectEqualStrings("queue", q.attributes.get("DeduplicationScope").?.string);
}

test "fifo-only attribute on standard queue rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(config.Error.InvalidAttributeName, loadBytes(arena, "{ \"ContentBasedDeduplication\": \"true\" }"));
}

test "invalid attribute fails fast" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(config.Error.InvalidAttributeValue, loadBytes(arena, "{ \"VisibilityTimeout\": \"99999\" }"));
    try testing.expectError(config.Error.InvalidAttributeName, loadBytes(arena, "{ \"Bogus\": \"1\" }"));
}

test "non-object top level rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(LoadError.InvalidConfig, loadBytes(arena, "[]"));
}
