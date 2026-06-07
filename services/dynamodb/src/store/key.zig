const std = @import("std");
const types = @import("../types.zig");

const AttributeValue = types.AttributeValue;
const ScalarKind = types.ScalarKind;

pub const KeyError = error{ MissingKeyAttribute, WrongKeyType };

const tag_s: u8 = 0x01;
const tag_n: u8 = 0x02;
const tag_b: u8 = 0x03;

// A scalar key part: its declared kind plus raw bytes (N stored canonical).
pub const Part = struct {
    kind: ScalarKind,
    bytes: []const u8,
};

// Pull a scalar key part out of an item by attribute name, validating its type.
pub fn partFromItem(item: types.Item, def: types.KeyDef) KeyError!Part {
    const v = item.attrs.get(def.name) orelse return KeyError.MissingKeyAttribute;
    return switch (def.kind) {
        .S => if (v == .S) .{ .kind = .S, .bytes = v.S } else KeyError.WrongKeyType,
        .N => if (v == .N) .{ .kind = .N, .bytes = v.N } else KeyError.WrongKeyType,
        .B => if (v == .B) .{ .kind = .B, .bytes = v.B } else KeyError.WrongKeyType,
    };
}

fn tagFor(kind: ScalarKind) u8 {
    return switch (kind) {
        .S => tag_s,
        .N => tag_n,
        .B => tag_b,
    };
}

// Deterministic byte encoding of a (partition[, sort]) key. Each part is
// `tag(1) || len(4 BE) || bytes`. Stable across restarts, so safe to hash for
// on-disk filenames.
pub fn encode(a: std.mem.Allocator, partition: Part, sort: ?Part) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try appendPart(a, &out, partition);
    if (sort) |s| try appendPart(a, &out, s);
    return out.toOwnedSlice(a);
}

fn appendPart(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), p: Part) !void {
    try out.append(a, tagFor(p.kind));
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(p.bytes.len), .big);
    try out.appendSlice(a, &len_be);
    try out.appendSlice(a, p.bytes);
}

pub fn encodeFromItem(a: std.mem.Allocator, item: types.Item, schema: types.KeySchema) ![]u8 {
    const pk = try partFromItem(item, schema.partition);
    const sk: ?Part = if (schema.sort) |sd| try partFromItem(item, sd) else null;
    return encode(a, pk, sk);
}

// SHA-256 hex of an encoded key — fits filesystem path limits.
pub fn hashHex(key_bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key_bytes, &digest, .{});
    const alphabet = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

// Order two scalar key parts of the same kind. S/B compare bytewise; N by value.
pub fn comparePart(a: Part, b: Part) std.math.Order {
    return switch (a.kind) {
        .S, .B => std.mem.order(u8, a.bytes, b.bytes),
        .N => types.compareNumber(a.bytes, b.bytes),
    };
}

const testing = std.testing;

fn put(item: *types.Item, alloc: std.mem.Allocator, name: []const u8, v: AttributeValue) !void {
    try item.attrs.put(alloc, name, v);
}

test "encode is deterministic and distinguishes parts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const k1 = try encode(a, .{ .kind = .S, .bytes = "user" }, .{ .kind = .N, .bytes = "7" });
    const k2 = try encode(a, .{ .kind = .S, .bytes = "user" }, .{ .kind = .N, .bytes = "7" });
    try testing.expectEqualSlices(u8, k1, k2);
    const k3 = try encode(a, .{ .kind = .S, .bytes = "user" }, .{ .kind = .N, .bytes = "8" });
    try testing.expect(!std.mem.eql(u8, k1, k3));
}

test "encodeFromItem pulls partition and sort" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var item: types.Item = .{};
    try put(&item, a, "pk", .{ .S = "abc" });
    try put(&item, a, "sk", .{ .N = "42" });
    const schema: types.KeySchema = .{
        .partition = .{ .name = "pk", .kind = .S },
        .sort = .{ .name = "sk", .kind = .N },
    };
    const enc = try encodeFromItem(a, item, schema);
    const expect = try encode(a, .{ .kind = .S, .bytes = "abc" }, .{ .kind = .N, .bytes = "42" });
    try testing.expectEqualSlices(u8, expect, enc);
}

test "missing/wrong key types error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var item: types.Item = .{};
    try put(&item, a, "pk", .{ .S = "abc" });
    try testing.expectError(KeyError.MissingKeyAttribute, partFromItem(item, .{ .name = "nope", .kind = .S }));
    try testing.expectError(KeyError.WrongKeyType, partFromItem(item, .{ .name = "pk", .kind = .N }));
}

test "comparePart orders S bytewise and N numerically" {
    try testing.expectEqual(std.math.Order.lt, comparePart(.{ .kind = .S, .bytes = "a" }, .{ .kind = .S, .bytes = "b" }));
    try testing.expectEqual(std.math.Order.lt, comparePart(.{ .kind = .N, .bytes = "9" }, .{ .kind = .N, .bytes = "10" }));
    try testing.expectEqual(std.math.Order.gt, comparePart(.{ .kind = .N, .bytes = "10" }, .{ .kind = .N, .bytes = "9" }));
}

test "hashHex deterministic 64 hex" {
    const h = hashHex("abc");
    try testing.expectEqualSlices(u8, &h, &hashHex("abc"));
    try testing.expect(!std.mem.eql(u8, &h, &hashHex("abd")));
}
