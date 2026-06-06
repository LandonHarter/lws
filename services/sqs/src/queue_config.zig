const std = @import("std");
const config = @import("config");
const attrs = @import("attrs.zig");

pub const QueueConfig = struct {
    name: ?[]const u8 = null,
    kind: config.QueueKind,
    attributes: std.StringArrayHashMapUnmanaged(config.Value),
};

pub const Loaded = struct {
    queues: []QueueConfig,
};

pub const LoadError = error{
    InvalidConfig,
} || config.Error || std.mem.Allocator.Error || std.Io.Dir.ReadFileAllocError || std.json.ParseError(std.json.Scanner);

const max_config_bytes = 4 * 1024 * 1024;

pub fn writeDefaults(kind: config.QueueKind, w: *std.Io.Writer) !void {
    try w.writeAll("{\n  \"defaults\": {\n");
    var first = true;
    for (&attrs.queue_attrs) |*spec| {
        if (spec.mutability == .read_only) continue;
        if (!config.appliesTo(spec, kind)) continue;
        const val = spec.default orelse continue;
        if (!first) try w.writeAll(",\n");
        first = false;
        try w.print("    \"{s}\": ", .{spec.name});
        switch (val) {
            .integer => |n| try w.print("\"{d}\"", .{n}),
            .boolean => |b| try w.writeAll(if (b) "\"true\"" else "\"false\""),
            .string => |s| try w.print("\"{s}\"", .{s}),
            .json => |j| try w.print("{s}", .{j}),
        }
    }
    try w.writeAll("\n  },\n  \"queues\": {}\n}\n");
}

pub fn loadFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!Loaded {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, std.Io.Limit.limited(max_config_bytes));
    return loadBytes(arena, bytes);
}

pub fn loadBytes(arena: std.mem.Allocator, bytes: []const u8) LoadError!Loaded {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (root != .object) {
        std.debug.print("sqs config: top-level value must be an object\n", .{});
        return LoadError.InvalidConfig;
    }
    const obj = root.object;

    if (obj.contains("queues") or obj.contains("defaults")) {
        return loadNested(arena, obj);
    }
    return loadFlat(arena, obj);
}

fn rawString(key: []const u8, v: std.json.Value) LoadError![]const u8 {
    if (v != .string) {
        std.debug.print("sqs config: attribute '{s}' value must be a string\n", .{key});
        return config.Error.InvalidAttributeValue;
    }
    return v.string;
}

fn loadNested(arena: std.mem.Allocator, obj: std.json.ObjectMap) LoadError!Loaded {
    var defaults: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    if (obj.get("defaults")) |d| {
        if (d != .object) {
            std.debug.print("sqs config: 'defaults' must be an object of attributes\n", .{});
            return LoadError.InvalidConfig;
        }
        var dit = d.object.iterator();
        while (dit.next()) |e| {
            try defaults.put(arena, e.key_ptr.*, try rawString(e.key_ptr.*, e.value_ptr.*));
        }
    }

    var list: std.ArrayListUnmanaged(QueueConfig) = .empty;
    if (obj.get("queues")) |q| {
        if (q != .object) {
            std.debug.print("sqs config: 'queues' must be an object mapping queue names to attributes\n", .{});
            return LoadError.InvalidConfig;
        }
        var qit = q.object.iterator();
        while (qit.next()) |qe| {
            const qname = qe.key_ptr.*;
            if (qe.value_ptr.* != .object) {
                std.debug.print("sqs config: queue '{s}' must map to an object of attributes\n", .{qname});
                return LoadError.InvalidConfig;
            }

            var merged: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
            var mdit = defaults.iterator();
            while (mdit.next()) |e| try merged.put(arena, e.key_ptr.*, e.value_ptr.*);
            var oit = qe.value_ptr.*.object.iterator();
            while (oit.next()) |e| {
                try merged.put(arena, e.key_ptr.*, try rawString(e.key_ptr.*, e.value_ptr.*));
            }

            try list.append(arena, try resolveRaw(arena, qname, &merged));
        }
    }

    return .{ .queues = try list.toOwnedSlice(arena) };
}

fn loadFlat(arena: std.mem.Allocator, obj: std.json.ObjectMap) LoadError!Loaded {
    var name: ?[]const u8 = null;
    var raw: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "QueueName")) {
            if (entry.value_ptr.* != .string) {
                std.debug.print("sqs config: 'QueueName' value must be a string\n", .{});
                return config.Error.InvalidAttributeValue;
            }
            name = entry.value_ptr.*.string;
            continue;
        }
        try raw.put(arena, key, try rawString(key, entry.value_ptr.*));
    }

    var list: std.ArrayListUnmanaged(QueueConfig) = .empty;
    try list.append(arena, try resolveRaw(arena, name, &raw));
    return .{ .queues = try list.toOwnedSlice(arena) };
}

fn resolveRaw(
    arena: std.mem.Allocator,
    name: ?[]const u8,
    raw: *const std.StringArrayHashMapUnmanaged([]const u8),
) LoadError!QueueConfig {
    const kind: config.QueueKind = blk: {
        if (raw.get("FifoQueue")) |v| {
            if (std.mem.eql(u8, v, "true")) break :blk .fifo;
        }
        break :blk .standard;
    };

    var map: std.StringArrayHashMapUnmanaged(config.Value) = .empty;
    for (attrs.queue_attrs) |spec| {
        if (spec.mutability == .read_only) continue;
        if (!config.appliesTo(&spec, kind)) continue;
        if (spec.default) |d| try map.put(arena, spec.name, d);
    }

    var it = raw.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        const resolved = config.validateOne(&attrs.queue_attrs, .create, kind, key, val) catch |err| {
            std.debug.print("sqs config: attribute '{s}'={s} rejected: {s}\n", .{ key, val, @errorName(err) });
            return err;
        };
        try map.put(arena, key, resolved);
    }

    return .{ .name = name, .kind = kind, .attributes = map };
}

const testing = std.testing;

fn loadOne(arena: std.mem.Allocator, bytes: []const u8) !QueueConfig {
    const loaded = try loadBytes(arena, bytes);
    try testing.expectEqual(@as(usize, 1), loaded.queues.len);
    return loaded.queues[0];
}

test "loads flat attribute config" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const q = try loadOne(arena, "{ \"FifoQueue\": \"true\", \"VisibilityTimeout\": \"60\", \"ContentBasedDeduplication\": \"true\" }");
    try testing.expectEqual(config.QueueKind.fifo, q.kind);
    try testing.expectEqual(@as(i64, 60), q.attributes.get("VisibilityTimeout").?.integer);
    try testing.expect(q.attributes.get("ContentBasedDeduplication").?.boolean);
}

test "defaults applied for unset attributes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const q = try loadOne(arena, "{}");
    try testing.expectEqual(config.QueueKind.standard, q.kind);
    try testing.expectEqual(@as(i64, 30), q.attributes.get("VisibilityTimeout").?.integer);
}

test "standard queue omits fifo-only defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const q = try loadOne(arena, "{}");
    try testing.expect(q.attributes.get("DeduplicationScope") == null);
}

test "fifo config gets fifo-only defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const q = try loadOne(arena, "{ \"FifoQueue\": \"true\" }");
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

test "QueueName extracted, not treated as attribute" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const q = try loadOne(arena, "{ \"QueueName\": \"x\", \"VisibilityTimeout\": \"60\" }");
    try testing.expectEqualStrings("x", q.name.?);
    try testing.expectEqual(@as(i64, 60), q.attributes.get("VisibilityTimeout").?.integer);
    try testing.expect(q.attributes.get("QueueName") == null);
}

test "no QueueName yields null name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const q = try loadOne(arena, "{ \"VisibilityTimeout\": \"60\" }");
    try testing.expect(q.name == null);
}

test "non-object top level rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(LoadError.InvalidConfig, loadBytes(arena, "[]"));
}

test "nested defaults applied to each queue, per-queue overrides win" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = try loadBytes(arena,
        \\{
        \\  "defaults": { "VisibilityTimeout": "60", "DelaySeconds": "5" },
        \\  "queues": {
        \\    "search": { "VisibilityTimeout": "120" },
        \\    "plain": {}
        \\  }
        \\}
    );
    try testing.expectEqual(@as(usize, 2), loaded.queues.len);

    const search = byName(loaded, "search").?;
    try testing.expectEqual(@as(i64, 120), search.attributes.get("VisibilityTimeout").?.integer);
    try testing.expectEqual(@as(i64, 5), search.attributes.get("DelaySeconds").?.integer);

    const plain = byName(loaded, "plain").?;
    try testing.expectEqual(@as(i64, 60), plain.attributes.get("VisibilityTimeout").?.integer);
    try testing.expectEqual(@as(i64, 5), plain.attributes.get("DelaySeconds").?.integer);
}

test "nested per-queue kind detected independently" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = try loadBytes(arena,
        \\{
        \\  "queues": {
        \\    "events.fifo": { "FifoQueue": "true", "ContentBasedDeduplication": "true" },
        \\    "plain": {}
        \\  }
        \\}
    );
    const fifo = byName(loaded, "events.fifo").?;
    try testing.expectEqual(config.QueueKind.fifo, fifo.kind);
    try testing.expect(fifo.attributes.get("ContentBasedDeduplication").?.boolean);

    const plain = byName(loaded, "plain").?;
    try testing.expectEqual(config.QueueKind.standard, plain.kind);
    try testing.expect(plain.attributes.get("DeduplicationScope") == null);
}

test "nested queue name carried as config name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = try loadBytes(arena, "{ \"queues\": { \"search\": {} } }");
    try testing.expectEqualStrings("search", loaded.queues[0].name.?);
}

test "defaults only, no queues, yields empty list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = try loadBytes(arena, "{ \"defaults\": { \"VisibilityTimeout\": \"60\" } }");
    try testing.expectEqual(@as(usize, 0), loaded.queues.len);
}

test "nested defaults not an object rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(LoadError.InvalidConfig, loadBytes(arena, "{ \"defaults\": \"x\", \"queues\": {} }"));
}

test "nested queue value not an object rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(LoadError.InvalidConfig, loadBytes(arena, "{ \"queues\": { \"search\": \"x\" } }"));
}

test "nested invalid attribute in a queue fails fast" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(config.Error.InvalidAttributeValue, loadBytes(arena, "{ \"queues\": { \"search\": { \"VisibilityTimeout\": \"99999\" } } }"));
}

fn byName(loaded: Loaded, name: []const u8) ?QueueConfig {
    for (loaded.queues) |q| {
        if (q.name != null and std.mem.eql(u8, q.name.?, name)) return q;
    }
    return null;
}
