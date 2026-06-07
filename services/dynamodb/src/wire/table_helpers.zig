const std = @import("std");
const types = @import("../types.zig");
const json_proto = @import("json_proto.zig");
const schema_io = @import("../persist/schema_io.zig");
const Runtime = @import("../runtime.zig").Runtime;

const Writer = json_proto.Writer;
const TableSchema = types.TableSchema;
const KeySchema = types.KeySchema;
const KeyDef = types.KeyDef;
const ScalarKind = types.ScalarKind;
const SecondaryIndex = types.SecondaryIndex;
const IndexProjection = types.IndexProjection;
const Tag = types.Tag;

pub const Err = error{ Validation, OutOfMemory };

// Carries the request arena plus the ValidationException message a parse helper
// fills in before returning error.Validation.
pub const Ctx = struct {
    arena: std.mem.Allocator,
    msg: []const u8 = "The request was invalid.",

    fn fail(self: *Ctx, msg: []const u8) Err {
        self.msg = msg;
        return error.Validation;
    }
};

// ---- json field access ----

fn objField(v: std.json.Value, name: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(name);
}

fn strField(v: std.json.Value, name: []const u8) ?[]const u8 {
    const f = objField(v, name) orelse return null;
    return if (f == .string) f.string else null;
}

pub fn requireTableName(c: *Ctx, body: std.json.Value) Err![]const u8 {
    const name = strField(body, "TableName") orelse return c.fail("TableName is required.");
    if (name.len == 0) return c.fail("TableName is required.");
    return name;
}

// ---- CreateTable parsing + validation ----

pub fn parseCreateTable(c: *Ctx, body: std.json.Value) Err!TableSchema {
    const name = try requireTableName(c, body);
    schema_io.validateName(name) catch return c.fail(
        "TableName must be between 3 and 255 characters and match the pattern [a-zA-Z0-9_.-]+.",
    );

    const defs = try parseAttributeDefs(c, body);

    const ks_v = objField(body, "KeySchema") orelse return c.fail("KeySchema is required.");
    const key_schema = try parseKeySchemaArr(c, defs, ks_v, true);

    var index_list: std.ArrayListUnmanaged(SecondaryIndex) = .empty;
    if (objField(body, "GlobalSecondaryIndexes")) |g| {
        if (g != .array) return c.fail("GlobalSecondaryIndexes must be a list.");
        for (g.array.items) |iv| {
            const idx = try parseIndex(c, defs, iv, .GSI, key_schema, &index_list);
            try index_list.append(c.arena, idx);
        }
    }
    if (objField(body, "LocalSecondaryIndexes")) |l| {
        if (l != .array) return c.fail("LocalSecondaryIndexes must be a list.");
        for (l.array.items) |iv| {
            const idx = try parseIndex(c, defs, iv, .LSI, key_schema, &index_list);
            try index_list.append(c.arena, idx);
        }
    }

    var billing: types.BillingMode = .PAY_PER_REQUEST;
    if (strField(body, "BillingMode")) |b| {
        billing = std.meta.stringToEnum(types.BillingMode, b) orelse
            return c.fail("BillingMode must be one of PROVISIONED or PAY_PER_REQUEST.");
    }

    const tags = try parseTags(c, objField(body, "Tags"));

    return .{
        .name = try c.arena.dupe(u8, name),
        .key_schema = key_schema,
        .attribute_defs = defs,
        .indexes = try index_list.toOwnedSlice(c.arena),
        .billing_mode = billing,
        .tags = tags,
    };
}

pub fn parseAttributeDefs(c: *Ctx, body: std.json.Value) Err![]KeyDef {
    const ad = objField(body, "AttributeDefinitions") orelse return c.fail("AttributeDefinitions is required.");
    if (ad != .array) return c.fail("AttributeDefinitions must be a list.");
    const out = try c.arena.alloc(KeyDef, ad.array.items.len);
    for (ad.array.items, 0..) |d, i| {
        if (d != .object) return c.fail("AttributeDefinitions entries must be objects.");
        const an = strField(d, "AttributeName") orelse return c.fail("AttributeName is required in AttributeDefinitions.");
        const at = strField(d, "AttributeType") orelse return c.fail("AttributeType is required in AttributeDefinitions.");
        const kind = scalarKind(at) orelse return c.fail("AttributeType must be one of S, N, or B.");
        out[i] = .{ .name = try c.arena.dupe(u8, an), .kind = kind };
    }
    return out;
}

fn scalarKind(s: []const u8) ?ScalarKind {
    if (std.mem.eql(u8, s, "S")) return .S;
    if (std.mem.eql(u8, s, "N")) return .N;
    if (std.mem.eql(u8, s, "B")) return .B;
    return null;
}

fn findDefKind(defs: []const KeyDef, name: []const u8) ?ScalarKind {
    for (defs) |d| if (std.mem.eql(u8, d.name, name)) return d.kind;
    return null;
}

// Parse a [{AttributeName,KeyType}] array into a KeySchema. `is_base` only
// changes the error wording. Every key attribute must appear in `defs`.
fn parseKeySchemaArr(c: *Ctx, defs: []const KeyDef, v: std.json.Value, is_base: bool) Err!KeySchema {
    _ = is_base;
    if (v != .array) return c.fail("KeySchema must be a list.");
    if (v.array.items.len < 1 or v.array.items.len > 2) return c.fail("KeySchema must contain 1 or 2 elements.");

    var partition: ?KeyDef = null;
    var sort: ?KeyDef = null;
    for (v.array.items) |e| {
        if (e != .object) return c.fail("KeySchema entries must be objects.");
        const an = strField(e, "AttributeName") orelse return c.fail("AttributeName is required in KeySchema.");
        const kt = strField(e, "KeyType") orelse return c.fail("KeyType is required in KeySchema.");
        const kind = findDefKind(defs, an) orelse
            return c.fail("One or more parameter values were invalid: Some index key attributes are not defined in AttributeDefinitions.");
        if (std.mem.eql(u8, kt, "HASH")) {
            if (partition != null) return c.fail("KeySchema may contain only one HASH key.");
            partition = .{ .name = try c.arena.dupe(u8, an), .kind = kind };
        } else if (std.mem.eql(u8, kt, "RANGE")) {
            if (sort != null) return c.fail("KeySchema may contain only one RANGE key.");
            sort = .{ .name = try c.arena.dupe(u8, an), .kind = kind };
        } else return c.fail("KeyType must be one of HASH or RANGE.");
    }
    const p = partition orelse return c.fail("KeySchema must contain exactly one HASH key.");
    return .{ .partition = p, .sort = sort };
}

pub fn parseIndex(
    c: *Ctx,
    defs: []const KeyDef,
    v: std.json.Value,
    kind: types.IndexKind,
    base: KeySchema,
    existing: *const std.ArrayListUnmanaged(SecondaryIndex),
) Err!SecondaryIndex {
    if (v != .object) return c.fail("Index definitions must be objects.");
    const iname = strField(v, "IndexName") orelse return c.fail("IndexName is required.");
    for (existing.items) |e| if (std.mem.eql(u8, e.name, iname)) return c.fail("Duplicate index name.");

    const ks_v = objField(v, "KeySchema") orelse return c.fail("KeySchema is required for index.");
    const ks = try parseKeySchemaArr(c, defs, ks_v, false);

    if (kind == .LSI and !std.mem.eql(u8, ks.partition.name, base.partition.name)) {
        return c.fail("LocalSecondaryIndex HASH key must match the table's HASH key.");
    }

    const pj_v = objField(v, "Projection") orelse return c.fail("Projection is required for index.");
    const projection = try parseProjection(c, pj_v);

    return .{ .name = try c.arena.dupe(u8, iname), .kind = kind, .schema = ks, .projection = projection };
}

fn parseProjection(c: *Ctx, v: std.json.Value) Err!IndexProjection {
    if (v != .object) return c.fail("Projection must be an object.");
    const pt = strField(v, "ProjectionType") orelse return c.fail("ProjectionType is required.");
    if (std.mem.eql(u8, pt, "ALL")) return .ALL;
    if (std.mem.eql(u8, pt, "KEYS_ONLY")) return .KEYS_ONLY;
    if (std.mem.eql(u8, pt, "INCLUDE")) {
        const nk = objField(v, "NonKeyAttributes") orelse
            return c.fail("NonKeyAttributes is required when ProjectionType is INCLUDE.");
        if (nk != .array or nk.array.items.len == 0)
            return c.fail("NonKeyAttributes is required when ProjectionType is INCLUDE.");
        const out = try c.arena.alloc([]const u8, nk.array.items.len);
        for (nk.array.items, 0..) |a, i| {
            if (a != .string) return c.fail("NonKeyAttributes entries must be strings.");
            out[i] = try c.arena.dupe(u8, a.string);
        }
        return .{ .INCLUDE = out };
    }
    return c.fail("ProjectionType must be one of KEYS_ONLY, INCLUDE, or ALL.");
}

pub fn parseTags(c: *Ctx, v: ?std.json.Value) Err![]Tag {
    const tv = v orelse return &.{};
    if (tv != .array) return c.fail("Tags must be a list.");
    if (tv.array.items.len > 50) return c.fail("A table may have at most 50 tags.");
    const out = try c.arena.alloc(Tag, tv.array.items.len);
    for (tv.array.items, 0..) |e, i| {
        if (e != .object) return c.fail("Tag entries must be objects.");
        const k = strField(e, "Key") orelse return c.fail("Tag Key is required.");
        const val = strField(e, "Value") orelse return c.fail("Tag Value is required.");
        out[i] = .{ .key = try c.arena.dupe(u8, k), .value = try c.arena.dupe(u8, val) };
    }
    return out;
}

// ---- TableDescription rendering ----

pub fn writeArn(w: *Writer, rt: *Runtime, name: []const u8) !void {
    const a = try std.fmt.allocPrint(w.arena, "arn:aws:dynamodb:{s}:{s}:table/{s}", .{ rt.region, rt.account, name });
    try w.writeString(a);
}

// Inner TableDescription object (begins + ends its own object frame).
pub fn writeTableDescription(w: *Writer, rt: *Runtime, s: TableSchema) !void {
    try w.beginObject();

    try w.writeKey("TableName");
    try w.writeString(s.name);

    try w.writeKey("TableArn");
    try writeArn(w, rt, s.name);

    try w.writeKey("TableId");
    try w.writeString(s.table_id);

    try w.writeKey("TableStatus");
    try w.writeString(@tagName(s.status));

    try w.writeKey("CreationDateTime");
    try writeEpochSeconds(w, s.created_at_ms);

    try w.writeKey("KeySchema");
    try writeKeySchemaJson(w, s.key_schema);

    try w.writeKey("AttributeDefinitions");
    try writeAttrDefsJson(w, s.attribute_defs);

    try writeIndexesJson(w, rt, s, .GSI, "GlobalSecondaryIndexes");
    try writeIndexesJson(w, rt, s, .LSI, "LocalSecondaryIndexes");

    try w.writeKey("BillingModeSummary");
    try w.beginObject();
    try w.writeKey("BillingMode");
    try w.writeString(@tagName(s.billing_mode));
    try w.writeKey("LastUpdateToPayPerRequestDateTime");
    try writeEpochSeconds(w, s.created_at_ms);
    try w.endObject();

    try w.writeKey("ProvisionedThroughput");
    try w.beginObject();
    try w.writeKey("ReadCapacityUnits");
    try w.writeInt(0);
    try w.writeKey("WriteCapacityUnits");
    try w.writeInt(0);
    try w.writeKey("NumberOfDecreasesToday");
    try w.writeInt(0);
    try w.endObject();

    try w.writeKey("ItemCount");
    try w.writeInt(@intCast(s.item_count));
    try w.writeKey("TableSizeBytes");
    try w.writeInt(@intCast(s.bytes));

    try w.endObject();
}

fn writeEpochSeconds(w: *Writer, ms: i64) !void {
    const seconds = @as(f64, @floatFromInt(ms)) / 1000.0;
    const s = try std.fmt.allocPrint(w.arena, "{d}", .{seconds});
    try w.writeRaw(s);
}

fn writeKeyDefEntry(w: *Writer, name: []const u8, key_type: []const u8) !void {
    try w.beginObject();
    try w.writeKey("AttributeName");
    try w.writeString(name);
    try w.writeKey("KeyType");
    try w.writeString(key_type);
    try w.endObject();
}

fn writeKeySchemaJson(w: *Writer, ks: KeySchema) !void {
    try w.beginArray();
    try writeKeyDefEntry(w, ks.partition.name, "HASH");
    if (ks.sort) |sd| try writeKeyDefEntry(w, sd.name, "RANGE");
    try w.endArray();
}

fn writeAttrDefsJson(w: *Writer, defs: []const KeyDef) !void {
    try w.beginArray();
    for (defs) |d| {
        try w.beginObject();
        try w.writeKey("AttributeName");
        try w.writeString(d.name);
        try w.writeKey("AttributeType");
        try w.writeString(@tagName(d.kind));
        try w.endObject();
    }
    try w.endArray();
}

fn writeProjectionJson(w: *Writer, p: IndexProjection) !void {
    try w.beginObject();
    try w.writeKey("ProjectionType");
    switch (p) {
        .ALL => try w.writeString("ALL"),
        .KEYS_ONLY => try w.writeString("KEYS_ONLY"),
        .INCLUDE => |attrs| {
            try w.writeString("INCLUDE");
            try w.writeKey("NonKeyAttributes");
            try w.beginArray();
            for (attrs) |an| try w.writeString(an);
            try w.endArray();
        },
    }
    try w.endObject();
}

fn writeIndexesJson(w: *Writer, rt: *Runtime, s: TableSchema, kind: types.IndexKind, field: []const u8) !void {
    var count: usize = 0;
    for (s.indexes) |idx| {
        if (idx.kind == kind) count += 1;
    }
    if (count == 0) return;

    try w.writeKey(field);
    try w.beginArray();
    for (s.indexes) |idx| {
        if (idx.kind != kind) continue;
        try w.beginObject();
        try w.writeKey("IndexName");
        try w.writeString(idx.name);
        try w.writeKey("KeySchema");
        try writeKeySchemaJson(w, idx.schema);
        try w.writeKey("Projection");
        try writeProjectionJson(w, idx.projection);
        try w.writeKey("IndexStatus");
        try w.writeString(@tagName(idx.status));
        try w.writeKey("IndexArn");
        const arn = try std.fmt.allocPrint(w.arena, "arn:aws:dynamodb:{s}:{s}:table/{s}/index/{s}", .{ rt.region, rt.account, s.name, idx.name });
        try w.writeString(arn);
        try w.writeKey("ItemCount");
        try w.writeInt(0);
        try w.writeKey("IndexSizeBytes");
        try w.writeInt(0);
        try w.endObject();
    }
    try w.endArray();
}

// ---- resource ARN -> table name ----
// arn:aws:dynamodb:<region>:<account>:table/<name>[/index/<idx>]
pub fn tableNameFromArn(arn: []const u8) ?[]const u8 {
    const marker = "table/";
    const at = std.mem.indexOf(u8, arn, marker) orelse return null;
    var rest = arn[at + marker.len ..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[0..slash];
    if (rest.len == 0) return null;
    return rest;
}

const testing = std.testing;

test "tableNameFromArn extracts table name" {
    try testing.expectEqualStrings("Users", tableNameFromArn("arn:aws:dynamodb:us-east-1:000000000000:table/Users").?);
    try testing.expectEqualStrings("Users", tableNameFromArn("arn:aws:dynamodb:us-east-1:000000000000:table/Users/index/by-email").?);
    try testing.expect(tableNameFromArn("arn:aws:sqs:us-east-1:0:queue/x") == null);
}

fn parseBody(a: std.mem.Allocator, json: []const u8) std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch unreachable;
}

test "parseCreateTable accepts a valid simple table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c: Ctx = .{ .arena = arena.allocator() };
    const body = parseBody(arena.allocator(),
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"S"}],
        \\"KeySchema":[{"AttributeName":"id","KeyType":"HASH"}],"BillingMode":"PAY_PER_REQUEST"}
    );
    const s = try parseCreateTable(&c, body);
    try testing.expectEqualStrings("Users", s.name);
    try testing.expectEqualStrings("id", s.key_schema.partition.name);
    try testing.expect(s.key_schema.sort == null);
}

test "parseCreateTable rejects missing TableName" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c: Ctx = .{ .arena = arena.allocator() };
    const body = parseBody(arena.allocator(), "{}");
    try testing.expectError(error.Validation, parseCreateTable(&c, body));
}

test "parseCreateTable rejects key not in attribute defs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c: Ctx = .{ .arena = arena.allocator() };
    const body = parseBody(arena.allocator(),
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"S"}],
        \\"KeySchema":[{"AttributeName":"missing","KeyType":"HASH"}]}
    );
    try testing.expectError(error.Validation, parseCreateTable(&c, body));
}

test "parseCreateTable rejects bad attribute type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c: Ctx = .{ .arena = arena.allocator() };
    const body = parseBody(arena.allocator(),
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"X"}],
        \\"KeySchema":[{"AttributeName":"id","KeyType":"HASH"}]}
    );
    try testing.expectError(error.Validation, parseCreateTable(&c, body));
}

test "parseCreateTable rejects LSI with mismatched hash key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c: Ctx = .{ .arena = arena.allocator() };
    const body = parseBody(arena.allocator(),
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"S"},
        \\{"AttributeName":"sk","AttributeType":"S"},{"AttributeName":"other","AttributeType":"S"}],
        \\"KeySchema":[{"AttributeName":"id","KeyType":"HASH"},{"AttributeName":"sk","KeyType":"RANGE"}],
        \\"LocalSecondaryIndexes":[{"IndexName":"lsi","KeySchema":[{"AttributeName":"other","KeyType":"HASH"},
        \\{"AttributeName":"sk","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}]}
    );
    try testing.expectError(error.Validation, parseCreateTable(&c, body));
}

test "parseCreateTable accepts GSI with INCLUDE projection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c: Ctx = .{ .arena = arena.allocator() };
    const body = parseBody(arena.allocator(),
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"S"},
        \\{"AttributeName":"email","AttributeType":"S"}],
        \\"KeySchema":[{"AttributeName":"id","KeyType":"HASH"}],
        \\"GlobalSecondaryIndexes":[{"IndexName":"by-email","KeySchema":[{"AttributeName":"email","KeyType":"HASH"}],
        \\"Projection":{"ProjectionType":"INCLUDE","NonKeyAttributes":["name"]}}]}
    );
    const s = try parseCreateTable(&c, body);
    try testing.expectEqual(@as(usize, 1), s.indexes.len);
    try testing.expectEqual(types.IndexKind.GSI, s.indexes[0].kind);
    try testing.expect(s.indexes[0].projection == .INCLUDE);
}

test "parseCreateTable rejects INCLUDE without NonKeyAttributes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c: Ctx = .{ .arena = arena.allocator() };
    const body = parseBody(arena.allocator(),
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"S"},
        \\{"AttributeName":"email","AttributeType":"S"}],
        \\"KeySchema":[{"AttributeName":"id","KeyType":"HASH"}],
        \\"GlobalSecondaryIndexes":[{"IndexName":"by-email","KeySchema":[{"AttributeName":"email","KeyType":"HASH"}],
        \\"Projection":{"ProjectionType":"INCLUDE"}}]}
    );
    try testing.expectError(error.Validation, parseCreateTable(&c, body));
}

test "parseCreateTable rejects bad billing mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c: Ctx = .{ .arena = arena.allocator() };
    const body = parseBody(arena.allocator(),
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"S"}],
        \\"KeySchema":[{"AttributeName":"id","KeyType":"HASH"}],"BillingMode":"WEIRD"}
    );
    try testing.expectError(error.Validation, parseCreateTable(&c, body));
}

test "parseCreateTable rejects too many tags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Ctx = .{ .arena = a };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(a,
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"S"}],
        \\"KeySchema":[{"AttributeName":"id","KeyType":"HASH"}],"Tags":[
    );
    var i: usize = 0;
    while (i < 51) : (i += 1) {
        if (i != 0) try buf.append(a, ',');
        const t = try std.fmt.allocPrint(a, "{{\"Key\":\"k{d}\",\"Value\":\"v\"}}", .{i});
        try buf.appendSlice(a, t);
    }
    try buf.appendSlice(a, "]}");
    const body = parseBody(a, buf.items);
    try testing.expectError(error.Validation, parseCreateTable(&c, body));
}
