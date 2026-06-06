const std = @import("std");

pub const AttrType = enum { integer, boolean, string, json };

pub const Value = union(AttrType) {
    integer: i64,
    boolean: bool,
    string: []const u8,
    json: []const u8,
};

pub const Mutability = enum { create_only, mutable, read_only };

pub const Applies = enum { all, fifo_only, standard_only };

pub const QueueKind = enum { standard, fifo };

pub const Op = enum { create, update };

pub const Error = error{
    InvalidAttributeName,
    InvalidAttributeValue,
};

pub const AttrSpec = struct {
    name: []const u8,
    type: AttrType,
    default: ?Value = null,
    min: ?i64 = null,
    max: ?i64 = null,
    mutability: Mutability = .mutable,
    applies: Applies = .all,
    allowed: ?[]const []const u8 = null,
};

pub fn appliesTo(spec: *const AttrSpec, kind: QueueKind) bool {
    return switch (spec.applies) {
        .all => true,
        .fifo_only => kind == .fifo,
        .standard_only => kind == .standard,
    };
}

pub fn writeDefaults(table: []const AttrSpec, kind: QueueKind, w: *std.Io.Writer) !void {
    try w.writeAll("{\n");
    var first = true;
    for (table) |*spec| {
        if (spec.mutability == .read_only) continue;
        if (!appliesTo(spec, kind)) continue;
        const val = spec.default orelse continue;
        if (!first) try w.writeAll(",\n");
        first = false;
        try w.print("  \"{s}\": ", .{spec.name});
        switch (val) {
            .integer => |n| try w.print("\"{d}\"", .{n}),
            .boolean => |b| try w.writeAll(if (b) "\"true\"" else "\"false\""),
            .string => |s| try w.print("\"{s}\"", .{s}),
            .json => |j| try w.print("{s}", .{j}),
        }
    }
    try w.writeAll("\n}\n");
}

pub fn lookup(table: []const AttrSpec, name: []const u8) ?*const AttrSpec {
    for (table) |*spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

pub fn defaultFor(table: []const AttrSpec, name: []const u8) ?Value {
    const spec = lookup(table, name) orelse return null;
    return spec.default;
}

pub fn parseValue(spec: *const AttrSpec, raw: []const u8) Error!Value {
    switch (spec.type) {
        .integer => {
            const n = std.fmt.parseInt(i64, raw, 10) catch return Error.InvalidAttributeValue;
            if (spec.min) |lo| if (n < lo) return Error.InvalidAttributeValue;
            if (spec.max) |hi| if (n > hi) return Error.InvalidAttributeValue;
            return .{ .integer = n };
        },
        .boolean => {
            if (std.mem.eql(u8, raw, "true")) return .{ .boolean = true };
            if (std.mem.eql(u8, raw, "false")) return .{ .boolean = false };
            return Error.InvalidAttributeValue;
        },
        .string => {
            if (spec.allowed) |set| {
                for (set) |opt| {
                    if (std.mem.eql(u8, opt, raw)) return .{ .string = raw };
                }
                return Error.InvalidAttributeValue;
            }
            return .{ .string = raw };
        },
        .json => return .{ .json = raw },
    }
}

fn checkPermission(spec: *const AttrSpec, op: Op, kind: QueueKind) Error!void {
    if (spec.mutability == .read_only) return Error.InvalidAttributeName;
    if (spec.mutability == .create_only and op == .update) return Error.InvalidAttributeName;
    switch (spec.applies) {
        .all => {},
        .fifo_only => if (kind == .standard) return Error.InvalidAttributeName,
        .standard_only => if (kind == .fifo) return Error.InvalidAttributeName,
    }
}

pub fn validateOne(
    table: []const AttrSpec,
    op: Op,
    kind: QueueKind,
    name: []const u8,
    raw: []const u8,
) Error!Value {
    const spec = lookup(table, name) orelse return Error.InvalidAttributeName;
    try checkPermission(spec, op, kind);
    return parseValue(spec, raw);
}

const testing = std.testing;

const test_table = [_]AttrSpec{
    .{ .name = "VisibilityTimeout", .type = .integer, .default = .{ .integer = 30 }, .min = 0, .max = 43200 },
    .{ .name = "FifoQueue", .type = .boolean, .default = .{ .boolean = false }, .mutability = .create_only },
    .{ .name = "ContentBasedDeduplication", .type = .boolean, .default = .{ .boolean = false }, .applies = .fifo_only },
    .{ .name = "DeduplicationScope", .type = .string, .default = .{ .string = "queue" }, .applies = .fifo_only, .allowed = &.{ "queue", "messageGroup" } },
    .{ .name = "QueueArn", .type = .string, .mutability = .read_only },
};

test "unknown attribute name" {
    try testing.expectError(Error.InvalidAttributeName, validateOne(&test_table, .create, .standard, "Nope", "1"));
}

test "integer in range" {
    const v = try validateOne(&test_table, .create, .standard, "VisibilityTimeout", "60");
    try testing.expectEqual(@as(i64, 60), v.integer);
}

test "integer out of range" {
    try testing.expectError(Error.InvalidAttributeValue, validateOne(&test_table, .create, .standard, "VisibilityTimeout", "99999"));
    try testing.expectError(Error.InvalidAttributeValue, validateOne(&test_table, .create, .standard, "VisibilityTimeout", "-1"));
}

test "integer unparseable" {
    try testing.expectError(Error.InvalidAttributeValue, validateOne(&test_table, .create, .standard, "VisibilityTimeout", "abc"));
}

test "boolean parse" {
    try testing.expect((try validateOne(&test_table, .create, .fifo, "FifoQueue", "true")).boolean);
    try testing.expectError(Error.InvalidAttributeValue, validateOne(&test_table, .create, .fifo, "FifoQueue", "yes"));
}

test "create_only rejected on update" {
    _ = try validateOne(&test_table, .create, .fifo, "FifoQueue", "true");
    try testing.expectError(Error.InvalidAttributeName, validateOne(&test_table, .update, .fifo, "FifoQueue", "true"));
}

test "fifo_only rejected on standard queue" {
    try testing.expectError(Error.InvalidAttributeName, validateOne(&test_table, .create, .standard, "ContentBasedDeduplication", "true"));
    _ = try validateOne(&test_table, .create, .fifo, "ContentBasedDeduplication", "true");
}

test "read_only cannot be set" {
    try testing.expectError(Error.InvalidAttributeName, validateOne(&test_table, .update, .standard, "QueueArn", "x"));
}

test "string allowed set" {
    const v = try validateOne(&test_table, .create, .fifo, "DeduplicationScope", "messageGroup");
    try testing.expectEqualStrings("messageGroup", v.string);
    try testing.expectError(Error.InvalidAttributeValue, validateOne(&test_table, .create, .fifo, "DeduplicationScope", "bogus"));
}

test "default lookup" {
    try testing.expectEqual(@as(i64, 30), defaultFor(&test_table, "VisibilityTimeout").?.integer);
    try testing.expectEqual(@as(?Value, null), defaultFor(&test_table, "QueueArn"));
}

test "writeDefaults standard omits fifo-only and read-only" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeDefaults(&test_table, .standard, &w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"VisibilityTimeout\": \"30\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"FifoQueue\": \"false\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "DeduplicationScope") == null);
    try testing.expect(std.mem.indexOf(u8, out, "QueueArn") == null);
}

test "writeDefaults fifo includes fifo-only" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeDefaults(&test_table, .fifo, &w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"DeduplicationScope\": \"queue\"") != null);
}
