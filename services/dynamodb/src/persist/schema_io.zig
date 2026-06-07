const std = @import("std");
const atomic = @import("atomic.zig");
const types = @import("../types.zig");

const TableSchema = types.TableSchema;
const KeySchema = types.KeySchema;
const KeyDef = types.KeyDef;
const SecondaryIndex = types.SecondaryIndex;
const IndexProjection = types.IndexProjection;

pub const schema_version: u32 = 1;
pub const ReadError = error{InvalidSchema};
pub const NameError = error{InvalidTableName};

const max_schema_bytes = 1 * 1024 * 1024;

// DynamoDB table names: 3-255 chars of [a-zA-Z0-9_.-]. The character set is a
// safe directory name (no separators, no traversal).
pub fn validateName(name: []const u8) NameError!void {
    if (name.len < 3 or name.len > 255) return NameError.InvalidTableName;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '.' or c == '-';
        if (!ok) return NameError.InvalidTableName;
    }
}

pub fn schemaPath(a: std.mem.Allocator, table_dir: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ table_dir, "schema.json" });
}

pub fn writeSchema(arena: std.mem.Allocator, io: std.Io, table_dir: []const u8, schema: TableSchema, fsync: bool) !void {
    try std.Io.Dir.createDirPath(.cwd(), io, table_dir);
    const body = try encode(arena, schema);
    const path = try schemaPath(arena, table_dir);
    try atomic.writeAtomic(io, path, body, fsync);
}

pub fn encode(arena: std.mem.Allocator, s: TableSchema) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.print("{{\"schema_version\":{d},\"name\":", .{schema_version});
    try writeJsonString(w, s.name);
    try w.writeAll(",\"key_schema\":");
    try writeKeySchema(w, s.key_schema);
    try w.writeAll(",\"attribute_defs\":[");
    for (s.attribute_defs, 0..) |d, i| {
        if (i != 0) try w.writeByte(',');
        try writeKeyDef(w, d);
    }
    try w.writeAll("],\"indexes\":[");
    for (s.indexes, 0..) |idx, i| {
        if (i != 0) try w.writeByte(',');
        try writeIndex(w, idx);
    }
    try w.print("],\"billing_mode\":\"{s}\"", .{@tagName(s.billing_mode)});
    try w.writeAll(",\"ttl_attribute\":");
    if (s.ttl_attribute) |t| try writeJsonString(w, t) else try w.writeAll("null");
    try w.print(",\"ttl_enabled\":{s},\"table_id\":", .{if (s.ttl_enabled) "true" else "false"});
    try writeJsonString(w, s.table_id);
    try w.writeAll(",\"tags\":[");
    for (s.tags, 0..) |t, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"key\":");
        try writeJsonString(w, t.key);
        try w.writeAll(",\"value\":");
        try writeJsonString(w, t.value);
        try w.writeByte('}');
    }
    try w.print("],\"created_at_ms\":{d},\"status\":\"{s}\",\"item_count\":{d},\"bytes\":{d}}}", .{
        s.created_at_ms, @tagName(s.status), s.item_count, s.bytes,
    });
    return aw.written();
}

fn writeKeyDef(w: *std.Io.Writer, d: KeyDef) !void {
    try w.writeAll("{\"name\":");
    try writeJsonString(w, d.name);
    try w.print(",\"kind\":\"{s}\"}}", .{@tagName(d.kind)});
}

fn writeKeySchema(w: *std.Io.Writer, ks: KeySchema) !void {
    try w.writeAll("{\"partition\":");
    try writeKeyDef(w, ks.partition);
    if (ks.sort) |s| {
        try w.writeAll(",\"sort\":");
        try writeKeyDef(w, s);
    }
    try w.writeByte('}');
}

fn writeIndex(w: *std.Io.Writer, idx: SecondaryIndex) !void {
    try w.writeAll("{\"name\":");
    try writeJsonString(w, idx.name);
    try w.print(",\"kind\":\"{s}\",\"schema\":", .{@tagName(idx.kind)});
    try writeKeySchema(w, idx.schema);
    try w.writeAll(",\"projection\":");
    switch (idx.projection) {
        .KEYS_ONLY => try w.writeAll("{\"type\":\"KEYS_ONLY\"}"),
        .ALL => try w.writeAll("{\"type\":\"ALL\"}"),
        .INCLUDE => |attrs| {
            try w.writeAll("{\"type\":\"INCLUDE\",\"attributes\":[");
            for (attrs, 0..) |at, i| {
                if (i != 0) try w.writeByte(',');
                try writeJsonString(w, at);
            }
            try w.writeAll("]}");
        },
    }
    try w.print(",\"status\":\"{s}\"}}", .{@tagName(idx.status)});
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

pub fn readSchema(arena: std.mem.Allocator, io: std.Io, table_dir: []const u8) !TableSchema {
    const path = try schemaPath(arena, table_dir);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, std.Io.Limit.limited(max_schema_bytes));
    return decode(arena, bytes);
}

pub fn decode(arena: std.mem.Allocator, bytes: []const u8) !TableSchema {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (root != .object) return ReadError.InvalidSchema;
    const obj = root.object;

    const name_v = obj.get("name") orelse return ReadError.InvalidSchema;
    if (name_v != .string) return ReadError.InvalidSchema;

    const ks_v = obj.get("key_schema") orelse return ReadError.InvalidSchema;
    const key_schema = try parseKeySchema(arena, ks_v);

    var attribute_defs: []KeyDef = &.{};
    if (obj.get("attribute_defs")) |ad| {
        if (ad != .array) return ReadError.InvalidSchema;
        const defs = try arena.alloc(KeyDef, ad.array.items.len);
        for (ad.array.items, 0..) |d, i| defs[i] = try parseKeyDef(arena, d);
        attribute_defs = defs;
    }

    var indexes: []SecondaryIndex = &.{};
    if (obj.get("indexes")) |ix| {
        if (ix != .array) return ReadError.InvalidSchema;
        const out = try arena.alloc(SecondaryIndex, ix.array.items.len);
        for (ix.array.items, 0..) |v, i| out[i] = try parseIndex(arena, v);
        indexes = out;
    }

    var schema: TableSchema = .{
        .name = try arena.dupe(u8, name_v.string),
        .key_schema = key_schema,
        .attribute_defs = attribute_defs,
        .indexes = indexes,
    };

    if (obj.get("billing_mode")) |b| {
        if (b == .string) schema.billing_mode = std.meta.stringToEnum(types.BillingMode, b.string) orelse .PAY_PER_REQUEST;
    }
    if (obj.get("ttl_attribute")) |t| {
        if (t == .string) schema.ttl_attribute = try arena.dupe(u8, t.string);
    }
    if (obj.get("ttl_enabled")) |t| {
        if (t == .bool) schema.ttl_enabled = t.bool;
    }
    if (obj.get("table_id")) |t| {
        if (t == .string) schema.table_id = try arena.dupe(u8, t.string);
    }
    if (obj.get("tags")) |tg| {
        if (tg == .array) {
            const out = try arena.alloc(types.Tag, tg.array.items.len);
            var n: usize = 0;
            for (tg.array.items) |tv| {
                if (tv != .object) continue;
                const k = tv.object.get("key") orelse continue;
                const v = tv.object.get("value") orelse continue;
                if (k != .string or v != .string) continue;
                out[n] = .{ .key = try arena.dupe(u8, k.string), .value = try arena.dupe(u8, v.string) };
                n += 1;
            }
            schema.tags = out[0..n];
        }
    }
    if (obj.get("created_at_ms")) |c| {
        if (c == .integer) schema.created_at_ms = c.integer;
    }
    if (obj.get("status")) |s| {
        if (s == .string) schema.status = std.meta.stringToEnum(types.TableStatus, s.string) orelse .ACTIVE;
    }
    if (obj.get("item_count")) |c| {
        if (c == .integer and c.integer >= 0) schema.item_count = @intCast(c.integer);
    }
    if (obj.get("bytes")) |c| {
        if (c == .integer and c.integer >= 0) schema.bytes = @intCast(c.integer);
    }
    return schema;
}

fn parseKeyDef(arena: std.mem.Allocator, v: std.json.Value) !KeyDef {
    if (v != .object) return ReadError.InvalidSchema;
    const name_v = v.object.get("name") orelse return ReadError.InvalidSchema;
    const kind_v = v.object.get("kind") orelse return ReadError.InvalidSchema;
    if (name_v != .string or kind_v != .string) return ReadError.InvalidSchema;
    const kind = std.meta.stringToEnum(types.ScalarKind, kind_v.string) orelse return ReadError.InvalidSchema;
    return .{ .name = try arena.dupe(u8, name_v.string), .kind = kind };
}

fn parseKeySchema(arena: std.mem.Allocator, v: std.json.Value) !KeySchema {
    if (v != .object) return ReadError.InvalidSchema;
    const p_v = v.object.get("partition") orelse return ReadError.InvalidSchema;
    var ks: KeySchema = .{ .partition = try parseKeyDef(arena, p_v) };
    if (v.object.get("sort")) |s_v| {
        if (s_v != .null) ks.sort = try parseKeyDef(arena, s_v);
    }
    return ks;
}

fn parseIndex(arena: std.mem.Allocator, v: std.json.Value) !SecondaryIndex {
    if (v != .object) return ReadError.InvalidSchema;
    const obj = v.object;
    const name_v = obj.get("name") orelse return ReadError.InvalidSchema;
    const kind_v = obj.get("kind") orelse return ReadError.InvalidSchema;
    const schema_v = obj.get("schema") orelse return ReadError.InvalidSchema;
    if (name_v != .string or kind_v != .string) return ReadError.InvalidSchema;

    var idx: SecondaryIndex = .{
        .name = try arena.dupe(u8, name_v.string),
        .kind = std.meta.stringToEnum(types.IndexKind, kind_v.string) orelse return ReadError.InvalidSchema,
        .schema = try parseKeySchema(arena, schema_v),
        .projection = .KEYS_ONLY,
    };

    if (obj.get("projection")) |pj| {
        if (pj != .object) return ReadError.InvalidSchema;
        const t_v = pj.object.get("type") orelse return ReadError.InvalidSchema;
        if (t_v != .string) return ReadError.InvalidSchema;
        if (std.mem.eql(u8, t_v.string, "ALL")) {
            idx.projection = .ALL;
        } else if (std.mem.eql(u8, t_v.string, "KEYS_ONLY")) {
            idx.projection = .KEYS_ONLY;
        } else if (std.mem.eql(u8, t_v.string, "INCLUDE")) {
            const at_v = pj.object.get("attributes") orelse return ReadError.InvalidSchema;
            if (at_v != .array) return ReadError.InvalidSchema;
            const attrs = try arena.alloc([]const u8, at_v.array.items.len);
            for (at_v.array.items, 0..) |a, i| {
                if (a != .string) return ReadError.InvalidSchema;
                attrs[i] = try arena.dupe(u8, a.string);
            }
            idx.projection = .{ .INCLUDE = attrs };
        } else return ReadError.InvalidSchema;
    }

    if (obj.get("status")) |s| {
        if (s == .string) idx.status = std.meta.stringToEnum(types.IndexStatus, s.string) orelse .ACTIVE;
    }
    return idx;
}

const testing = std.testing;

test "validateName" {
    try validateName("Orders");
    try validateName("my.table-1_v2");
    try testing.expectError(NameError.InvalidTableName, validateName("ab"));
    try testing.expectError(NameError.InvalidTableName, validateName("bad/name"));
    try testing.expectError(NameError.InvalidTableName, validateName("bad name"));
}

test "schema round-trip with sort key, GSI, INCLUDE projection, ttl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var include = [_][]const u8{ "name", "email" };
    var indexes = [_]SecondaryIndex{.{
        .name = "by-email",
        .kind = .GSI,
        .schema = .{ .partition = .{ .name = "email", .kind = .S } },
        .projection = .{ .INCLUDE = &include },
        .status = .ACTIVE,
    }};
    var defs = [_]KeyDef{
        .{ .name = "pk", .kind = .S },
        .{ .name = "sk", .kind = .N },
        .{ .name = "email", .kind = .S },
    };
    const schema: TableSchema = .{
        .name = "users",
        .key_schema = .{ .partition = .{ .name = "pk", .kind = .S }, .sort = .{ .name = "sk", .kind = .N } },
        .attribute_defs = &defs,
        .indexes = &indexes,
        .billing_mode = .PAY_PER_REQUEST,
        .ttl_attribute = "expires",
        .created_at_ms = 1717689600000,
        .status = .ACTIVE,
        .item_count = 7,
        .bytes = 123,
    };

    const body = try encode(a, schema);
    const got = try decode(a, body);

    try testing.expectEqualStrings("users", got.name);
    try testing.expectEqualStrings("pk", got.key_schema.partition.name);
    try testing.expectEqual(types.ScalarKind.N, got.key_schema.sort.?.kind);
    try testing.expectEqual(@as(usize, 3), got.attribute_defs.len);
    try testing.expectEqual(@as(usize, 1), got.indexes.len);
    try testing.expectEqualStrings("by-email", got.indexes[0].name);
    try testing.expectEqual(types.IndexKind.GSI, got.indexes[0].kind);
    try testing.expect(got.indexes[0].projection == .INCLUDE);
    try testing.expectEqual(@as(usize, 2), got.indexes[0].projection.INCLUDE.len);
    try testing.expectEqualStrings("expires", got.ttl_attribute.?);
    try testing.expectEqual(@as(i64, 1717689600000), got.created_at_ms);
    try testing.expectEqual(@as(u64, 7), got.item_count);
    try testing.expectEqual(@as(u64, 123), got.bytes);
}
