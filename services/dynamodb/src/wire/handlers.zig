const std = @import("std");
const id = @import("core").id;
const Runtime = @import("../runtime.zig").Runtime;
const errors = @import("../errors.zig");
const types = @import("../types.zig");
const envelope = @import("envelope.zig");
const json_proto = @import("json_proto.zig");
const helpers = @import("table_helpers.zig");

const Request = envelope.Request;
const Response = envelope.Response;
const Writer = json_proto.Writer;
const TableSchema = types.TableSchema;

fn ok(body: []const u8) Response {
    return .{ .status = 200, .body = body };
}

fn fail(req: *const Request, code: errors.Code, msg: []const u8) Response {
    const body = errors.render(req.arena.allocator(), code, msg) catch "";
    return .{ .status = errors.httpStatus(code), .body = body };
}

const not_found_msg = "Cannot do operations on a non-existent table";

// CreateTable/DeleteTable/UpdateTable wrap in "TableDescription"; DescribeTable
// wraps the same shape in "Table".
fn tableResponse(rt: *Runtime, req: *Request, s: TableSchema, wrapper: []const u8) !Response {
    var w = Writer.init(req.arena.allocator());
    try w.beginObject();
    try w.writeKey(wrapper);
    try helpers.writeTableDescription(&w, rt, s);
    try w.endObject();
    return ok(w.finish());
}

fn intField(body: std.json.Value, name: []const u8) ?i64 {
    if (body != .object) return null;
    const f = body.object.get(name) orelse return null;
    return if (f == .integer) f.integer else null;
}

fn strField(body: std.json.Value, name: []const u8) ?[]const u8 {
    if (body != .object) return null;
    const f = body.object.get(name) orelse return null;
    return if (f == .string) f.string else null;
}

pub fn createTable(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    var c: helpers.Ctx = .{ .arena = a };
    var schema = helpers.parseCreateTable(&c, req.body) catch |e| switch (e) {
        error.Validation => return fail(req, .validation_exception, c.msg),
        else => return e,
    };

    if (rt.registry.lookup(schema.name) != null) {
        const msg = try std.fmt.allocPrint(a, "Table already exists: {s}", .{schema.name});
        return fail(req, .resource_in_use_exception, msg);
    }

    var tid: [36]u8 = undefined;
    id.uuidV4(rt.rng, &tid);
    schema.table_id = try a.dupe(u8, &tid);

    const t = try rt.registry.createTable(schema);
    return tableResponse(rt, req, t.schema, "TableDescription");
}

pub fn describeTable(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    var c: helpers.Ctx = .{ .arena = a };
    const name = helpers.requireTableName(&c, req.body) catch |e| switch (e) {
        error.Validation => return fail(req, .validation_exception, c.msg),
        else => return e,
    };
    const t = rt.registry.lookup(name) orelse return fail(req, .resource_not_found_exception, not_found_msg);
    return tableResponse(rt, req, t.schema, "Table");
}

pub fn listTables(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();

    var limit: usize = 100;
    if (intField(req.body, "Limit")) |l| {
        if (l > 0) limit = @min(@as(usize, @intCast(l)), 100);
    }
    const start: ?[]const u8 = strField(req.body, "ExclusiveStartTableName");

    const page = try rt.registry.list(a, .{ .limit = limit, .exclusive_start = start });

    var w = Writer.init(a);
    try w.beginObject();
    try w.writeKey("TableNames");
    try w.beginArray();
    for (page.names) |n| try w.writeString(n);
    try w.endArray();
    if (page.last_name) |last| {
        try w.writeKey("LastEvaluatedTableName");
        try w.writeString(last);
    }
    try w.endObject();
    return ok(w.finish());
}

pub fn deleteTable(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    var c: helpers.Ctx = .{ .arena = a };
    const name = helpers.requireTableName(&c, req.body) catch |e| switch (e) {
        error.Validation => return fail(req, .validation_exception, c.msg),
        else => return e,
    };
    const t = rt.registry.lookup(name) orelse return fail(req, .resource_not_found_exception, not_found_msg);

    // Render the echo (status DELETING) while the table arena is still valid,
    // then tear the table down.
    t.schema.status = .DELETING;
    const resp = try tableResponse(rt, req, t.schema, "TableDescription");
    try rt.registry.deleteTable(name);
    return resp;
}

pub fn updateTable(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    var c: helpers.Ctx = .{ .arena = a };
    const name = helpers.requireTableName(&c, req.body) catch |e| switch (e) {
        error.Validation => return fail(req, .validation_exception, c.msg),
        else => return e,
    };
    const t = rt.registry.lookup(name) orelse return fail(req, .resource_not_found_exception, not_found_msg);

    if (strField(req.body, "BillingMode")) |b| {
        const mode = std.meta.stringToEnum(types.BillingMode, b) orelse
            return fail(req, .validation_exception, "BillingMode must be one of PROVISIONED or PAY_PER_REQUEST.");
        try rt.registry.setBillingMode(t, mode);
    }

    if (req.body.object.get("GlobalSecondaryIndexUpdates")) |gsiu| {
        if (gsiu != .array) return fail(req, .validation_exception, "GlobalSecondaryIndexUpdates must be a list.");

        var extra_defs: []types.KeyDef = &.{};
        if (req.body.object.get("AttributeDefinitions")) |_| {
            extra_defs = helpers.parseAttributeDefs(&c, req.body) catch |e| switch (e) {
                error.Validation => return fail(req, .validation_exception, c.msg),
                else => return e,
            };
        }
        const combined = try combineDefs(a, t.schema.attribute_defs, extra_defs);

        for (gsiu.array.items) |upd| {
            if (upd != .object) return fail(req, .validation_exception, "GlobalSecondaryIndexUpdates entries must be objects.");
            if (upd.object.get("Create")) |create| {
                var existing: std.ArrayListUnmanaged(types.SecondaryIndex) = .empty;
                for (t.schema.indexes) |ix| try existing.append(a, ix);
                const idx = helpers.parseIndex(&c, combined, create, .GSI, t.schema.key_schema, &existing) catch |e| switch (e) {
                    error.Validation => return fail(req, .validation_exception, c.msg),
                    else => return e,
                };
                try rt.registry.addIndex(t, idx, extra_defs);
            } else if (upd.object.get("Delete")) |del| {
                const iname = strField(del, "IndexName") orelse
                    return fail(req, .validation_exception, "IndexName is required to delete an index.");
                rt.registry.dropIndex(t, iname) catch |e| switch (e) {
                    error.IndexNotFound => return fail(req, .validation_exception, "Index not found."),
                    else => return e,
                };
            }
            // Update -> no-op (we don't enforce throughput).
        }
    }

    t.schema.status = .ACTIVE;
    return tableResponse(rt, req, t.schema, "TableDescription");
}

fn combineDefs(a: std.mem.Allocator, base: []const types.KeyDef, extra: []const types.KeyDef) ![]types.KeyDef {
    var out: std.ArrayListUnmanaged(types.KeyDef) = .empty;
    for (base) |d| try out.append(a, d);
    for (extra) |d| {
        var dup = false;
        for (out.items) |e| if (std.mem.eql(u8, e.name, d.name)) {
            dup = true;
            break;
        };
        if (!dup) try out.append(a, d);
    }
    return out.toOwnedSlice(a);
}

pub fn updateTimeToLive(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    var c: helpers.Ctx = .{ .arena = a };
    const name = helpers.requireTableName(&c, req.body) catch |e| switch (e) {
        error.Validation => return fail(req, .validation_exception, c.msg),
        else => return e,
    };
    const t = rt.registry.lookup(name) orelse return fail(req, .resource_not_found_exception, not_found_msg);

    const spec = req.body.object.get("TimeToLiveSpecification") orelse
        return fail(req, .validation_exception, "TimeToLiveSpecification is required.");
    if (spec != .object) return fail(req, .validation_exception, "TimeToLiveSpecification must be an object.");
    const enabled_v = spec.object.get("Enabled") orelse
        return fail(req, .validation_exception, "TimeToLiveSpecification.Enabled is required.");
    if (enabled_v != .bool) return fail(req, .validation_exception, "TimeToLiveSpecification.Enabled must be a boolean.");
    const attr = strField(spec, "AttributeName") orelse
        return fail(req, .validation_exception, "TimeToLiveSpecification.AttributeName is required.");

    try rt.registry.updateTtl(t, enabled_v.bool, attr);

    var w = Writer.init(a);
    try w.beginObject();
    try w.writeKey("TimeToLiveSpecification");
    try w.beginObject();
    try w.writeKey("Enabled");
    try w.writeBool(enabled_v.bool);
    try w.writeKey("AttributeName");
    try w.writeString(attr);
    try w.endObject();
    try w.endObject();
    return ok(w.finish());
}

pub fn describeTimeToLive(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    var c: helpers.Ctx = .{ .arena = a };
    const name = helpers.requireTableName(&c, req.body) catch |e| switch (e) {
        error.Validation => return fail(req, .validation_exception, c.msg),
        else => return e,
    };
    const t = rt.registry.lookup(name) orelse return fail(req, .resource_not_found_exception, not_found_msg);

    var w = Writer.init(a);
    try w.beginObject();
    try w.writeKey("TimeToLiveDescription");
    try w.beginObject();
    try w.writeKey("TimeToLiveStatus");
    try w.writeString(if (t.schema.ttl_enabled) "ENABLED" else "DISABLED");
    if (t.schema.ttl_enabled) {
        if (t.schema.ttl_attribute) |attr| {
            try w.writeKey("AttributeName");
            try w.writeString(attr);
        }
    }
    try w.endObject();
    try w.endObject();
    return ok(w.finish());
}

fn resolveTableByArn(rt: *Runtime, req: *Request) !union(enum) { table: *@import("../store/item_store.zig").Table, err: Response } {
    const arn = strField(req.body, "ResourceArn") orelse
        return .{ .err = fail(req, .validation_exception, "ResourceArn is required.") };
    const name = helpers.tableNameFromArn(arn) orelse
        return .{ .err = fail(req, .validation_exception, "Invalid ResourceArn.") };
    const t = rt.registry.lookup(name) orelse
        return .{ .err = fail(req, .resource_not_found_exception, not_found_msg) };
    return .{ .table = t };
}

pub fn tagResource(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    const resolved = try resolveTableByArn(rt, req);
    const t = switch (resolved) {
        .err => |r| return r,
        .table => |t| t,
    };
    var c: helpers.Ctx = .{ .arena = a };
    const tags_v = req.body.object.get("Tags") orelse
        return fail(req, .validation_exception, "Tags is required.");
    const tags = helpers.parseTags(&c, tags_v) catch |e| switch (e) {
        error.Validation => return fail(req, .validation_exception, c.msg),
        else => return e,
    };
    try rt.registry.putTags(t, tags);
    return ok("{}");
}

pub fn untagResource(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    const resolved = try resolveTableByArn(rt, req);
    const t = switch (resolved) {
        .err => |r| return r,
        .table => |t| t,
    };
    const keys_v = req.body.object.get("TagKeys") orelse
        return fail(req, .validation_exception, "TagKeys is required.");
    if (keys_v != .array) return fail(req, .validation_exception, "TagKeys must be a list.");
    const keys = try a.alloc([]const u8, keys_v.array.items.len);
    for (keys_v.array.items, 0..) |kv, i| {
        if (kv != .string) return fail(req, .validation_exception, "TagKeys entries must be strings.");
        keys[i] = kv.string;
    }
    try rt.registry.removeTags(t, keys);
    return ok("{}");
}

pub fn listTagsOfResource(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    const resolved = try resolveTableByArn(rt, req);
    const t = switch (resolved) {
        .err => |r| return r,
        .table => |t| t,
    };

    var w = Writer.init(a);
    try w.beginObject();
    try w.writeKey("Tags");
    try w.beginArray();
    for (t.schema.tags) |tag| {
        try w.beginObject();
        try w.writeKey("Key");
        try w.writeString(tag.key);
        try w.writeKey("Value");
        try w.writeString(tag.value);
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
    return ok(w.finish());
}

// ---- tests ----

const testing = std.testing;
const time = @import("core").time;
const Registry = @import("../registry.zig").Registry;

const TestEnv = struct {
    threaded: *std.Io.Threaded,
    tmp: std.testing.TmpDir,
    registry: *Registry,
    rt: *Runtime,
    prng: *std.Random.DefaultPrng,
    data_dir: []u8,

    fn init() !TestEnv {
        const a = testing.allocator;
        const threaded = try a.create(std.Io.Threaded);
        threaded.* = std.Io.Threaded.init(a, .{});
        const io = threaded.io();

        const tmp = std.testing.tmpDir(.{});
        const data_dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

        const prng = try a.create(std.Random.DefaultPrng);
        prng.* = std.Random.DefaultPrng.init(42);

        const registry = try a.create(Registry);
        registry.* = Registry.init(a, io, data_dir, false, time.Clock.fixed(1717689600, 1717689600000), prng.random());

        const rt = try a.create(Runtime);
        rt.* = .{ .gpa = a, .io = io, .clock = time.Clock.fixed(1717689600, 1717689600000), .rng = prng.random(), .registry = registry };

        return .{ .threaded = threaded, .tmp = tmp, .registry = registry, .rt = rt, .prng = prng, .data_dir = data_dir };
    }

    fn deinit(self: *TestEnv) void {
        const a = testing.allocator;
        self.registry.deinit();
        self.tmp.cleanup();
        self.threaded.deinit();
        a.destroy(self.rt);
        a.destroy(self.registry);
        a.destroy(self.prng);
        a.destroy(self.threaded);
        a.free(self.data_dir);
    }

    fn call(self: *TestEnv, arena: *std.heap.ArenaAllocator, handler: anytype, json: []const u8) !Response {
        const body = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
        var req: Request = .{ .target = .create_table, .body = body, .request_id = [_]u8{'0'} ** 36, .arena = arena };
        return handler(self.rt, &req);
    }
};

test "createTable round-trips into the registry and renders ACTIVE" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const resp = try env.call(&arena, createTable,
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"S"}],
        \\"KeySchema":[{"AttributeName":"id","KeyType":"HASH"}],"BillingMode":"PAY_PER_REQUEST"}
    );
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"TableStatus\":\"ACTIVE\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "arn:aws:dynamodb:us-east-1:000000000000:table/Users") != null);
    try testing.expect(env.registry.lookup("Users") != null);
}

test "createTable on existing table returns ResourceInUse" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const json =
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"S"}],
        \\"KeySchema":[{"AttributeName":"id","KeyType":"HASH"}]}
    ;
    _ = try env.call(&arena, createTable, json);
    const resp = try env.call(&arena, createTable, json);
    try testing.expectEqual(@as(u16, 400), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "ResourceInUseException") != null);
}

test "describeTable missing yields ResourceNotFound" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resp = try env.call(&arena, describeTable, "{\"TableName\":\"Nope\"}");
    try testing.expectEqual(@as(u16, 400), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "ResourceNotFoundException") != null);
}

test "listTables paginates with Limit" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "alpha", "bravo", "charlie" }) |name| {
        const json = try std.fmt.allocPrint(arena.allocator(),
            \\{{"TableName":"{s}","AttributeDefinitions":[{{"AttributeName":"id","AttributeType":"S"}}],
            \\"KeySchema":[{{"AttributeName":"id","KeyType":"HASH"}}]}}
        , .{name});
        _ = try env.call(&arena, createTable, json);
    }
    const resp = try env.call(&arena, listTables, "{\"Limit\":1}");
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"alpha\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"LastEvaluatedTableName\":\"alpha\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"bravo\"") == null);
}

test "deleteTable removes the table and echoes DELETING" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try env.call(&arena, createTable,
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"S"}],
        \\"KeySchema":[{"AttributeName":"id","KeyType":"HASH"}]}
    );
    const resp = try env.call(&arena, deleteTable, "{\"TableName\":\"Users\"}");
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"TableStatus\":\"DELETING\"") != null);
    try testing.expect(env.registry.lookup("Users") == null);
}

test "tags round-trip via tag/list/untag" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try env.call(&arena, createTable,
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"S"}],
        \\"KeySchema":[{"AttributeName":"id","KeyType":"HASH"}]}
    );
    const arn = "{\"ResourceArn\":\"arn:aws:dynamodb:us-east-1:000000000000:table/Users\"";
    _ = try env.call(&arena, tagResource, arn ++ ",\"Tags\":[{\"Key\":\"env\",\"Value\":\"prod\"}]}");
    const listed = try env.call(&arena, listTagsOfResource, arn ++ "}");
    try testing.expect(std.mem.indexOf(u8, listed.body, "\"Key\":\"env\"") != null);
    try testing.expect(std.mem.indexOf(u8, listed.body, "\"Value\":\"prod\"") != null);
    _ = try env.call(&arena, untagResource, arn ++ ",\"TagKeys\":[\"env\"]}");
    const listed2 = try env.call(&arena, listTagsOfResource, arn ++ "}");
    try testing.expect(std.mem.indexOf(u8, listed2.body, "\"env\"") == null);
}

test "ttl enable then describe" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try env.call(&arena, createTable,
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"S"}],
        \\"KeySchema":[{"AttributeName":"id","KeyType":"HASH"}]}
    );
    _ = try env.call(&arena, updateTimeToLive,
        \\{"TableName":"Users","TimeToLiveSpecification":{"Enabled":true,"AttributeName":"expires"}}
    );
    const desc = try env.call(&arena, describeTimeToLive, "{\"TableName\":\"Users\"}");
    try testing.expect(std.mem.indexOf(u8, desc.body, "\"TimeToLiveStatus\":\"ENABLED\"") != null);
    try testing.expect(std.mem.indexOf(u8, desc.body, "\"AttributeName\":\"expires\"") != null);
}

test "updateTable adds a GSI and backfills" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try env.call(&arena, createTable,
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"id","AttributeType":"S"}],
        \\"KeySchema":[{"AttributeName":"id","KeyType":"HASH"}]}
    );

    // seed an item directly so backfill has something to index
    const t = env.registry.lookup("Users").?;
    {
        const a = t.arena.allocator();
        var item: @import("../types.zig").Item = .{};
        try item.attrs.put(a, "id", .{ .S = "u1" });
        try item.attrs.put(a, "email", .{ .S = "a@b.com" });
        _ = try t.putItem(item, false);
    }

    const resp = try env.call(&arena, updateTable,
        \\{"TableName":"Users","AttributeDefinitions":[{"AttributeName":"email","AttributeType":"S"}],
        \\"GlobalSecondaryIndexUpdates":[{"Create":{"IndexName":"by-email",
        \\"KeySchema":[{"AttributeName":"email","KeyType":"HASH"}],"Projection":{"ProjectionType":"ALL"}}}]}
    );
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"IndexName\":\"by-email\"") != null);
    try testing.expectEqual(@as(usize, 1), t.schema.indexes.len);

    var qarena = std.heap.ArenaAllocator.init(testing.allocator);
    defer qarena.deinit();
    const page = try t.queryIndex(qarena.allocator(), t.schema.indexes[0].schema, .{
        .partition = .{ .kind = .S, .bytes = "a@b.com" },
    }, .{});
    try testing.expectEqual(@as(usize, 1), page.items.len);

    // delete it again: index dropped from schema and the dir torn down
    _ = try env.call(&arena, updateTable,
        \\{"TableName":"Users","GlobalSecondaryIndexUpdates":[{"Delete":{"IndexName":"by-email"}}]}
    );
    try testing.expectEqual(@as(usize, 0), t.schema.indexes.len);
    var pbuf: [256]u8 = undefined;
    const idx_dir = try std.fmt.bufPrint(&pbuf, "{s}/tables/Users/indexes/by-email", .{env.data_dir});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(env.rt.io, idx_dir, .{}));
}
