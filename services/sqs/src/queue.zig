const std = @import("std");
const config = @import("config");
const attrs = @import("attrs.zig");

pub const Kind = config.QueueKind;

pub const AttrMap = std.StringArrayHashMapUnmanaged(config.Value);
pub const TagMap = std.StringArrayHashMapUnmanaged([]const u8);

pub const Queue = struct {
    id: [16]u8,
    name: []const u8,
    kind: Kind,
    attributes: AttrMap,
    tags: TagMap,
    created_at: i64,
    last_modified_at: i64,
    arena: *std.heap.ArenaAllocator,
    mutex: std.Io.Mutex = .init,
};

pub const NameError = error{InvalidQueueName};

pub fn validateName(name: []const u8, kind: Kind) NameError!void {
    if (name.len == 0 or name.len > 80) return error.InvalidQueueName;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return error.InvalidQueueName;
    }
    const has_fifo_suffix = std.mem.endsWith(u8, name, ".fifo");
    switch (kind) {
        .fifo => if (!has_fifo_suffix) return error.InvalidQueueName,
        .standard => if (has_fifo_suffix) return error.InvalidQueueName,
    }
}

pub fn deriveKind(raw_attrs: *const TagMap) Kind {
    if (raw_attrs.get("FifoQueue")) |v| {
        if (std.mem.eql(u8, v, "true")) return .fifo;
    }
    return .standard;
}

fn dupeValue(arena: std.mem.Allocator, v: config.Value) !config.Value {
    return switch (v) {
        .integer => |n| .{ .integer = n },
        .boolean => |b| .{ .boolean = b },
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .json => |j| .{ .json = try arena.dupe(u8, j) },
    };
}

// Applies defaults for `kind`, then validates+overrides each raw attribute.
// All keys and string payloads are duped into `arena`.
pub fn buildAttributes(arena: std.mem.Allocator, raw_attrs: *const TagMap, kind: Kind) !AttrMap {
    var map: AttrMap = .empty;
    for (attrs.queue_attrs) |spec| {
        if (spec.mutability == .read_only) continue;
        const applies = switch (spec.applies) {
            .all => true,
            .fifo_only => kind == .fifo,
            .standard_only => kind == .standard,
        };
        if (!applies) continue;
        if (spec.default) |d| try map.put(arena, spec.name, d);
    }

    var it = raw_attrs.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const raw = entry.value_ptr.*;
        const resolved = try config.validateOne(&attrs.queue_attrs, .create, kind, key, raw);
        try map.put(arena, try arena.dupe(u8, key), try dupeValue(arena, resolved));
    }
    return map;
}

pub fn valueEql(a: config.Value, b: config.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .integer => |n| n == b.integer,
        .boolean => |x| x == b.boolean,
        .string => |s| std.mem.eql(u8, s, b.string),
        .json => |j| std.mem.eql(u8, j, b.json),
    };
}

pub fn attributesEql(a: *const AttrMap, b: *const AttrMap) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |e| {
        const other = b.get(e.key_ptr.*) orelse return false;
        if (!valueEql(e.value_ptr.*, other)) return false;
    }
    return true;
}

const testing = std.testing;

test "validateName accepts good standard name" {
    try validateName("good_name", .standard);
    try validateName("a-b-c", .standard);
}

test "validateName rejects fifo suffix on standard" {
    try testing.expectError(error.InvalidQueueName, validateName("badname.fifo", .standard));
}

test "validateName requires fifo suffix on fifo" {
    try validateName("ok.fifo", .fifo);
    try testing.expectError(error.InvalidQueueName, validateName("noffifo", .fifo));
}

test "validateName length bounds" {
    try testing.expectError(error.InvalidQueueName, validateName("", .standard));
    const long = "n" ** 81;
    try testing.expectError(error.InvalidQueueName, validateName(long, .standard));
}

test "validateName rejects bad chars" {
    try testing.expectError(error.InvalidQueueName, validateName("bad name", .standard));
    try testing.expectError(error.InvalidQueueName, validateName("bad/name", .standard));
}

test "deriveKind reads FifoQueue raw attr" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var raw: TagMap = .empty;
    try testing.expectEqual(Kind.standard, deriveKind(&raw));
    try raw.put(arena.allocator(), "FifoQueue", "true");
    try testing.expectEqual(Kind.fifo, deriveKind(&raw));
}

test "buildAttributes applies defaults and overrides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var raw: TagMap = .empty;
    try raw.put(a, "VisibilityTimeout", "60");
    const map = try buildAttributes(a, &raw, .standard);
    try testing.expectEqual(@as(i64, 60), map.get("VisibilityTimeout").?.integer);
    try testing.expectEqual(@as(i64, 0), map.get("DelaySeconds").?.integer);
}

test "buildAttributes rejects bad value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var raw: TagMap = .empty;
    try raw.put(a, "VisibilityTimeout", "99999");
    try testing.expectError(config.Error.InvalidAttributeValue, buildAttributes(a, &raw, .standard));
}

test "attributesEql detects differences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r1: TagMap = .empty;
    var r2: TagMap = .empty;
    try r1.put(a, "VisibilityTimeout", "60");
    try r2.put(a, "VisibilityTimeout", "60");
    const m1 = try buildAttributes(a, &r1, .standard);
    const m2 = try buildAttributes(a, &r2, .standard);
    try testing.expect(attributesEql(&m1, &m2));

    var r3: TagMap = .empty;
    try r3.put(a, "VisibilityTimeout", "30");
    const m3 = try buildAttributes(a, &r3, .standard);
    try testing.expect(!attributesEql(&m1, &m3));
}
