const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const errors = @import("../errors.zig");
const types = @import("../types.zig");
const envelope = @import("envelope.zig");
const json_proto = @import("json_proto.zig");
const helpers = @import("table_helpers.zig");
const item_store = @import("../store/item_store.zig");
const key = @import("../store/key.zig");
const parser = @import("../expr/parser.zig");
const eval = @import("../expr/eval.zig");

const Request = envelope.Request;
const Response = envelope.Response;
const Writer = json_proto.Writer;
const Table = item_store.Table;
const Item = types.Item;
const AttributeValue = types.AttributeValue;
const KeySchema = types.KeySchema;
const Subst = eval.Subst;

const not_found_msg = "Requested resource not found";

fn ok(body: []const u8) Response {
    return .{ .status = 200, .body = body };
}

fn fail(req: *const Request, code: errors.Code, msg: []const u8) Response {
    const body = errors.render(req.arena.allocator(), code, msg) catch "";
    return .{ .status = errors.httpStatus(code), .body = body };
}

// ---- shared request parsing ----

const SubstError = error{Validation} || std.mem.Allocator.Error;

fn buildSubst(a: std.mem.Allocator, body: std.json.Value) SubstError!Subst {
    var s: Subst = .{};
    if (body != .object) return s;
    if (body.object.get("ExpressionAttributeNames")) |n| {
        if (n != .object) return error.Validation;
        var it = n.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .string) return error.Validation;
            try s.names.put(a, e.key_ptr.*, e.value_ptr.*.string);
        }
    }
    if (body.object.get("ExpressionAttributeValues")) |v| {
        if (v != .object) return error.Validation;
        var it = v.object.iterator();
        while (it.next()) |e| {
            const av = json_proto.parseAttributeValue(a, e.value_ptr.*) catch return error.Validation;
            try s.values.put(a, e.key_ptr.*, av);
        }
    }
    return s;
}

fn resolveName(subst: *const Subst, tok: []const u8) ?[]const u8 {
    if (tok.len > 0 and tok[0] == '#') return subst.names.get(tok);
    return tok;
}

// Parse the request's "Item" or "Key" field into an Item, validating the
// primary key is present and well-typed. Returns the item and its encoded key.
const KeyedItem = struct { item: Item, key_enc: []u8 };

fn parseKeyed(a: std.mem.Allocator, v: std.json.Value, schema: KeySchema) !KeyedItem {
    const item = json_proto.parseItem(a, v) catch return error.BadItem;
    const enc = key.encodeFromItem(a, item, schema) catch return error.BadKey;
    return .{ .item = item, .key_enc = enc };
}

fn encodeKeyFromMap(a: std.mem.Allocator, v: ?std.json.Value, schema: KeySchema) !?[]u8 {
    const mv = v orelse return null;
    const item = json_proto.parseItem(a, mv) catch return error.BadKey;
    return key.encodeFromItem(a, item, schema) catch return error.BadKey;
}

// Emit the LastEvaluatedKey / key map for an item: base partition (+sort) and,
// for an index query, the index partition (+sort) attributes too.
fn writeKeyMap(w: *Writer, item: Item, base: KeySchema, index: ?KeySchema) !void {
    try w.beginObject();
    var seen: [4][]const u8 = undefined;
    var n: usize = 0;
    const emit = struct {
        fn one(ww: *Writer, it: Item, name: []const u8, seen_buf: *[4][]const u8, cnt: *usize) !void {
            for (seen_buf[0..cnt.*]) |s| if (std.mem.eql(u8, s, name)) return;
            if (it.attrs.get(name)) |val| {
                try ww.writeKey(name);
                try json_proto.writeAttributeValue(ww, val);
                seen_buf[cnt.*] = name;
                cnt.* += 1;
            }
        }
    }.one;
    try emit(w, item, base.partition.name, &seen, &n);
    if (base.sort) |sd| try emit(w, item, sd.name, &seen, &n);
    if (index) |ix| {
        try emit(w, item, ix.partition.name, &seen, &n);
        if (ix.sort) |sd| try emit(w, item, sd.name, &seen, &n);
    }
    try w.endObject();
}

// ---- ReturnValues ----

fn writeReturnValues(w: *Writer, a: std.mem.Allocator, rv: []const u8, old: ?Item, after: ?Item, changed: []const []const u8) !void {
    if (std.mem.eql(u8, rv, "ALL_OLD")) {
        if (old) |o| {
            try w.writeKey("Attributes");
            try json_proto.writeItem(w, o);
        }
    } else if (std.mem.eql(u8, rv, "ALL_NEW")) {
        if (after) |n| {
            try w.writeKey("Attributes");
            try json_proto.writeItem(w, n);
        }
    } else if (std.mem.eql(u8, rv, "UPDATED_OLD")) {
        if (old) |o| try writeSubset(w, a, o, changed);
    } else if (std.mem.eql(u8, rv, "UPDATED_NEW")) {
        if (after) |n| try writeSubset(w, a, n, changed);
    }
}

fn writeSubset(w: *Writer, a: std.mem.Allocator, src: Item, names: []const []const u8) !void {
    var sub: Item = .{};
    for (names) |name| {
        if (src.attrs.get(name)) |v| try sub.attrs.put(a, name, v);
    }
    if (sub.attrs.count() == 0) return;
    try w.writeKey("Attributes");
    try json_proto.writeItem(w, sub);
}

fn returnValuesField(body: std.json.Value) []const u8 {
    if (body != .object) return "NONE";
    const f = body.object.get("ReturnValues") orelse return "NONE";
    return if (f == .string) f.string else "NONE";
}

// ---- PutItem ----

const PutCtx = struct {
    cond: ?*const parser.BoolExpr,
    subst: *const Subst,
    scratch: std.mem.Allocator,
    item: Item,
    eval_err: ?anyerror = null,
};

fn putDecide(ctx_ptr: *anyopaque, current: ?Item, a: std.mem.Allocator) anyerror!Table.Decision {
    const ctx: *PutCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.cond) |c| {
        const passed = eval.evalBool(ctx.scratch, c, current, ctx.subst) catch |e| {
            ctx.eval_err = e;
            return .condition_failed;
        };
        if (!passed) return .condition_failed;
    }
    const cloned = try item_store.cloneItem(a, ctx.item);
    return .{ .proceed = .{ .put = cloned } };
}

pub fn putItem(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    var c: helpers.Ctx = .{ .arena = a };
    const name = helpers.requireTableName(&c, req.body) catch return fail(req, .validation_exception, c.msg);
    const t = rt.registry.lookup(name) orelse return fail(req, .resource_not_found_exception, not_found_msg);

    const item_v = objField(req.body, "Item") orelse return fail(req, .validation_exception, "Item is required.");
    const keyed = parseKeyed(a, item_v, t.schema.key_schema) catch |e| return mapItemErr(req, e);

    var subst = buildSubst(a, req.body) catch return fail(req, .validation_exception, "Invalid expression attributes.");
    const cond = compileCondition(a, req.body, "ConditionExpression") catch return fail(req, .validation_exception, "Invalid ConditionExpression.");

    var ctx: PutCtx = .{ .cond = cond, .subst = &subst, .scratch = a, .item = keyed.item };
    const outcome = try t.mutate(keyed.key_enc, &ctx, putDecide);
    if (ctx.eval_err != null) return fail(req, .validation_exception, "ConditionExpression references undefined names or values.");
    if (!outcome.applied) return fail(req, .conditional_check_failed_exception, "The conditional request failed");

    const rv = returnValuesField(req.body);
    var w = Writer.init(a);
    try w.beginObject();
    try writeReturnValues(&w, a, rv, outcome.old, null, &.{});
    try w.endObject();
    return ok(w.finish());
}

// ---- GetItem ----

pub fn getItem(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    var c: helpers.Ctx = .{ .arena = a };
    const name = helpers.requireTableName(&c, req.body) catch return fail(req, .validation_exception, c.msg);
    const t = rt.registry.lookup(name) orelse return fail(req, .resource_not_found_exception, not_found_msg);

    const key_v = objField(req.body, "Key") orelse return fail(req, .validation_exception, "Key is required.");
    const keyed = parseKeyed(a, key_v, t.schema.key_schema) catch |e| return mapItemErr(req, e);

    var w = Writer.init(a);
    try w.beginObject();
    const found = t.getItem(keyed.key_enc);
    if (found) |item| {
        if (!expired(t, item, rt)) {
            try w.writeKey("Item");
            writeProjected(&w, a, req.body, item) catch
                return fail(req, .validation_exception, "Invalid ProjectionExpression.");
        }
    }
    try w.endObject();
    return ok(w.finish());
}

fn writeProjected(w: *Writer, a: std.mem.Allocator, body: std.json.Value, item: Item) !void {
    const pe = strField(body, "ProjectionExpression");
    if (pe == null) {
        try json_proto.writeItem(w, item);
        return;
    }
    var subst = try buildSubst(a, body);
    const proj = parser.parseProjection(a, pe.?) catch return error.BadProjection;
    const projected = eval.project(a, proj, item, &subst) catch return error.BadProjection;
    try json_proto.writeItem(w, projected);
}

// TTL: an item whose ttl attribute is a past epoch-second number reads as absent.
fn expired(t: *Table, item: Item, rt: *Runtime) bool {
    if (!t.schema.ttl_enabled) return false;
    const attr = t.schema.ttl_attribute orelse return false;
    const v = item.attrs.get(attr) orelse return false;
    if (v != .N) return false;
    const exp = std.fmt.parseFloat(f64, v.N) catch return false;
    return @as(f64, @floatFromInt(rt.clock.nowSec())) > exp;
}

// ---- DeleteItem ----

const DeleteCtx = struct {
    cond: ?*const parser.BoolExpr,
    subst: *const Subst,
    scratch: std.mem.Allocator,
    eval_err: ?anyerror = null,
};

fn deleteDecide(ctx_ptr: *anyopaque, current: ?Item, a: std.mem.Allocator) anyerror!Table.Decision {
    _ = a;
    const ctx: *DeleteCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.cond) |cnd| {
        const passed = eval.evalBool(ctx.scratch, cnd, current, ctx.subst) catch |e| {
            ctx.eval_err = e;
            return .condition_failed;
        };
        if (!passed) return .condition_failed;
    }
    return .{ .proceed = .delete };
}

pub fn deleteItem(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    var c: helpers.Ctx = .{ .arena = a };
    const name = helpers.requireTableName(&c, req.body) catch return fail(req, .validation_exception, c.msg);
    const t = rt.registry.lookup(name) orelse return fail(req, .resource_not_found_exception, not_found_msg);

    const key_v = objField(req.body, "Key") orelse return fail(req, .validation_exception, "Key is required.");
    const keyed = parseKeyed(a, key_v, t.schema.key_schema) catch |e| return mapItemErr(req, e);

    var subst = buildSubst(a, req.body) catch return fail(req, .validation_exception, "Invalid expression attributes.");
    const cond = compileCondition(a, req.body, "ConditionExpression") catch return fail(req, .validation_exception, "Invalid ConditionExpression.");

    var ctx: DeleteCtx = .{ .cond = cond, .subst = &subst, .scratch = a };
    const outcome = try t.mutate(keyed.key_enc, &ctx, deleteDecide);
    if (ctx.eval_err != null) return fail(req, .validation_exception, "ConditionExpression references undefined names or values.");
    if (!outcome.applied) return fail(req, .conditional_check_failed_exception, "The conditional request failed");

    const rv = returnValuesField(req.body);
    var w = Writer.init(a);
    try w.beginObject();
    try writeReturnValues(&w, a, rv, outcome.old, null, &.{});
    try w.endObject();
    return ok(w.finish());
}

// ---- UpdateItem ----

const UpdateCtx = struct {
    cond: ?*const parser.BoolExpr,
    prog: parser.UpdateProgram,
    subst: *const Subst,
    scratch: std.mem.Allocator,
    seed: Item, // Key attributes to seed a fresh item on upsert
    result: ?eval.ApplyResult = null,
    eval_err: ?anyerror = null,
};

fn updateDecide(ctx_ptr: *anyopaque, current: ?Item, a: std.mem.Allocator) anyerror!Table.Decision {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.cond) |cnd| {
        const passed = eval.evalBool(ctx.scratch, cnd, current, ctx.subst) catch |e| {
            ctx.eval_err = e;
            return .condition_failed;
        };
        if (!passed) return .condition_failed;
    }
    const base: ?Item = current orelse ctx.seed;
    const res = eval.applyUpdate(a, ctx.prog, base, ctx.subst) catch |e| {
        ctx.eval_err = e;
        return .condition_failed;
    };
    ctx.result = res;
    return .{ .proceed = .{ .put = res.after } };
}

pub fn updateItem(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    var c: helpers.Ctx = .{ .arena = a };
    const name = helpers.requireTableName(&c, req.body) catch return fail(req, .validation_exception, c.msg);
    const t = rt.registry.lookup(name) orelse return fail(req, .resource_not_found_exception, not_found_msg);

    const key_v = objField(req.body, "Key") orelse return fail(req, .validation_exception, "Key is required.");
    const keyed = parseKeyed(a, key_v, t.schema.key_schema) catch |e| return mapItemErr(req, e);

    var prog: parser.UpdateProgram = .{};
    if (strField(req.body, "UpdateExpression")) |ue| {
        prog = parser.parseUpdate(a, ue) catch return fail(req, .validation_exception, "Invalid UpdateExpression.");
    }
    var subst = buildSubst(a, req.body) catch return fail(req, .validation_exception, "Invalid expression attributes.");
    const cond = compileCondition(a, req.body, "ConditionExpression") catch return fail(req, .validation_exception, "Invalid ConditionExpression.");

    var ctx: UpdateCtx = .{ .cond = cond, .prog = prog, .subst = &subst, .scratch = a, .seed = keyed.item };
    const outcome = try t.mutate(keyed.key_enc, &ctx, updateDecide);
    if (ctx.eval_err != null) return fail(req, .validation_exception, "UpdateExpression or ConditionExpression is invalid.");
    if (!outcome.applied) return fail(req, .conditional_check_failed_exception, "The conditional request failed");

    const rv = returnValuesField(req.body);
    const changed: []const []const u8 = if (ctx.result) |r| r.changed else &.{};
    const after: ?Item = if (ctx.result) |r| r.after else null;
    var w = Writer.init(a);
    try w.beginObject();
    try writeReturnValues(&w, a, rv, outcome.old, after, changed);
    try w.endObject();
    return ok(w.finish());
}

// ---- Query ----

pub fn query(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    var c: helpers.Ctx = .{ .arena = a };
    const name = helpers.requireTableName(&c, req.body) catch return fail(req, .validation_exception, c.msg);
    const t = rt.registry.lookup(name) orelse return fail(req, .resource_not_found_exception, not_found_msg);

    // Resolve index vs base table.
    var index_schema: ?KeySchema = null;
    if (strField(req.body, "IndexName")) |iname| {
        var found = false;
        for (t.schema.indexes) |idx| {
            if (std.mem.eql(u8, idx.name, iname)) {
                index_schema = idx.schema;
                found = true;
                break;
            }
        }
        if (!found) return fail(req, .validation_exception, "The specified index does not exist.");
    }
    const search_schema = index_schema orelse t.schema.key_schema;

    const kce = strField(req.body, "KeyConditionExpression") orelse
        return fail(req, .validation_exception, "KeyConditionExpression is required.");
    var subst = buildSubst(a, req.body) catch return fail(req, .validation_exception, "Invalid expression attributes.");
    const parsed = parser.parseKeyCondition(a, kce) catch
        return fail(req, .validation_exception, "Invalid KeyConditionExpression.");

    var store_cond: item_store.KeyCondition = undefined;
    buildStoreKeyCond(parsed, search_schema, &subst, &store_cond) catch
        return fail(req, .validation_exception, "KeyConditionExpression must target the table or index key.");

    const forward = if (req.body.object.get("ScanIndexForward")) |f| (if (f == .bool) f.bool else true) else true;
    const limit = limitField(req.body);
    const esk = encodeKeyFromMap(a, req.body.object.get("ExclusiveStartKey"), t.schema.key_schema) catch
        return fail(req, .validation_exception, "Invalid ExclusiveStartKey.");

    const opts: item_store.QueryOpts = .{ .limit = limit, .exclusive_start = esk, .forward = forward };
    const page = if (index_schema) |ix|
        try t.queryIndex(a, ix, store_cond, opts)
    else
        try t.query(a, store_cond, opts);

    return renderItemsPage(req, a, page, index_schema, t.schema.key_schema);
}

fn buildStoreKeyCond(kc: parser.KeyCondition, schema: KeySchema, subst: *const Subst, out: *item_store.KeyCondition) !void {
    const pk_name = resolveName(subst, kc.pk_name) orelse return error.Validation;
    if (!std.mem.eql(u8, pk_name, schema.partition.name)) return error.Validation;
    const pkv = subst.values.get(kc.pk_value) orelse return error.Validation;
    out.* = .{ .partition = (keyPartFromValue(pkv, schema.partition.kind) orelse return error.Validation) };
    out.sort_op = .none;
    if (kc.sort) |sc| {
        const sd = schema.sort orelse return error.Validation;
        const sname = resolveName(subst, sc.name) orelse return error.Validation;
        if (!std.mem.eql(u8, sname, sd.name)) return error.Validation;
        const av = subst.values.get(sc.a) orelse return error.Validation;
        out.sort_a = keyPartFromValue(av, sd.kind) orelse return error.Validation;
        out.sort_op = switch (sc.op) {
            .eq => .eq,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            .begins_with => .begins_with,
            .between => blk: {
                const bv = subst.values.get(sc.b.?) orelse return error.Validation;
                out.sort_b = keyPartFromValue(bv, sd.kind) orelse return error.Validation;
                break :blk .between;
            },
        };
    }
}

fn keyPartFromValue(v: AttributeValue, kind: types.ScalarKind) ?key.Part {
    return switch (kind) {
        .S => if (v == .S) key.Part{ .kind = .S, .bytes = v.S } else null,
        .N => if (v == .N) key.Part{ .kind = .N, .bytes = v.N } else null,
        .B => if (v == .B) key.Part{ .kind = .B, .bytes = v.B } else null,
    };
}

// ---- Scan ----

pub fn scan(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    var c: helpers.Ctx = .{ .arena = a };
    const name = helpers.requireTableName(&c, req.body) catch return fail(req, .validation_exception, c.msg);
    const t = rt.registry.lookup(name) orelse return fail(req, .resource_not_found_exception, not_found_msg);

    const limit = limitField(req.body);
    const esk = encodeKeyFromMap(a, req.body.object.get("ExclusiveStartKey"), t.schema.key_schema) catch
        return fail(req, .validation_exception, "Invalid ExclusiveStartKey.");
    const page = try t.scan(a, .{ .limit = limit, .exclusive_start = esk });

    return renderItemsPage(req, a, page, null, t.schema.key_schema);
}

// Apply FilterExpression + ProjectionExpression to a page and emit the standard
// {Items, Count, ScannedCount, LastEvaluatedKey} envelope.
fn renderItemsPage(req: *Request, a: std.mem.Allocator, page: item_store.Page, index: ?KeySchema, base: KeySchema) anyerror!Response {
    var subst = buildSubst(a, req.body) catch return fail(req, .validation_exception, "Invalid expression attributes.");
    var filter: ?*const parser.BoolExpr = null;
    if (strField(req.body, "FilterExpression")) |fe| {
        filter = parser.parseFilter(a, fe) catch return fail(req, .validation_exception, "Invalid FilterExpression.");
    }
    var proj: ?parser.Projection = null;
    if (strField(req.body, "ProjectionExpression")) |pe| {
        proj = parser.parseProjection(a, pe) catch return fail(req, .validation_exception, "Invalid ProjectionExpression.");
    }

    var matched: std.ArrayListUnmanaged(Item) = .empty;
    for (page.items) |item| {
        if (filter) |f| {
            const keep = eval.evalBool(a, f, item, &subst) catch
                return fail(req, .validation_exception, "FilterExpression is invalid.");
            if (!keep) continue;
        }
        const out_item = if (proj) |p| (eval.project(a, p, item, &subst) catch
            return fail(req, .validation_exception, "ProjectionExpression is invalid.")) else item;
        try matched.append(a, out_item);
    }

    var w = Writer.init(a);
    try w.beginObject();
    try w.writeKey("Items");
    try w.beginArray();
    for (matched.items) |item| try json_proto.writeItem(&w, item);
    try w.endArray();
    try w.writeKey("Count");
    try w.writeInt(@intCast(matched.items.len));
    try w.writeKey("ScannedCount");
    try w.writeInt(@intCast(page.items.len));
    if (page.last_key != null and page.items.len > 0) {
        try w.writeKey("LastEvaluatedKey");
        try writeKeyMap(&w, page.items[page.items.len - 1], base, index);
    }
    try w.endObject();
    return ok(w.finish());
}

// ---- small shared helpers ----

fn objField(body: std.json.Value, n: []const u8) ?std.json.Value {
    if (body != .object) return null;
    return body.object.get(n);
}

fn strField(body: std.json.Value, n: []const u8) ?[]const u8 {
    const f = objField(body, n) orelse return null;
    return if (f == .string) f.string else null;
}

fn limitField(body: std.json.Value) usize {
    if (objField(body, "Limit")) |l| {
        if (l == .integer and l.integer > 0) return @intCast(l.integer);
    }
    return 0;
}

fn compileCondition(a: std.mem.Allocator, body: std.json.Value, field: []const u8) !?*const parser.BoolExpr {
    const ce = strField(body, field) orelse return null;
    return try parser.parseCondition(a, ce);
}

fn mapItemErr(req: *const Request, e: anyerror) Response {
    return switch (e) {
        error.BadItem => fail(req, .validation_exception, "The provided item is not a valid AttributeValue map."),
        error.BadKey => fail(req, .validation_exception, "One or more parameter values were invalid: the key is missing or malformed."),
        else => fail(req, .validation_exception, "The request was invalid."),
    };
}

// ---- BatchGetItem ----

pub fn batchGetItem(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    const ri = objField(req.body, "RequestItems") orelse return fail(req, .validation_exception, "RequestItems is required.");
    if (ri != .object) return fail(req, .validation_exception, "RequestItems must be an object.");

    var total: usize = 0;
    var it = ri.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .object) return fail(req, .validation_exception, "RequestItems entries must be objects.");
        const keys = e.value_ptr.*.object.get("Keys") orelse return fail(req, .validation_exception, "Keys is required.");
        if (keys != .array) return fail(req, .validation_exception, "Keys must be a list.");
        total += keys.array.items.len;
    }
    if (total > 100) return fail(req, .validation_exception, "Too many items requested for the BatchGetItem call (max 100).");

    var w = Writer.init(a);
    try w.beginObject();
    try w.writeKey("Responses");
    try w.beginObject();
    var it2 = ri.object.iterator();
    while (it2.next()) |e| {
        const tname = e.key_ptr.*;
        const spec = e.value_ptr.*;
        const t = rt.registry.lookup(tname) orelse return fail(req, .resource_not_found_exception, not_found_msg);
        try w.writeKey(tname);
        try w.beginArray();
        const keys = spec.object.get("Keys").?;
        for (keys.array.items) |kv| {
            const keyed = parseKeyed(a, kv, t.schema.key_schema) catch |err| return mapItemErr(req, err);
            const found = t.getItem(keyed.key_enc) orelse continue;
            if (expired(t, found, rt)) continue;
            writeProjected(&w, a, spec, found) catch return fail(req, .validation_exception, "Invalid ProjectionExpression.");
        }
        try w.endArray();
    }
    try w.endObject();
    try w.writeKey("UnprocessedKeys");
    try w.beginObject();
    try w.endObject();
    try w.endObject();
    return ok(w.finish());
}

// ---- BatchWriteItem ----

const PlainPutCtx = struct { item: Item };
fn plainPut(ctx_ptr: *anyopaque, current: ?Item, a: std.mem.Allocator) anyerror!Table.Decision {
    _ = current;
    const ctx: *PlainPutCtx = @ptrCast(@alignCast(ctx_ptr));
    return .{ .proceed = .{ .put = try item_store.cloneItem(a, ctx.item) } };
}
fn plainDelete(ctx_ptr: *anyopaque, current: ?Item, a: std.mem.Allocator) anyerror!Table.Decision {
    _ = ctx_ptr;
    _ = current;
    _ = a;
    return .{ .proceed = .delete };
}

pub fn batchWriteItem(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    const ri = objField(req.body, "RequestItems") orelse return fail(req, .validation_exception, "RequestItems is required.");
    if (ri != .object) return fail(req, .validation_exception, "RequestItems must be an object.");

    var total: usize = 0;
    var it = ri.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .array) return fail(req, .validation_exception, "RequestItems entries must be lists.");
        total += e.value_ptr.*.array.items.len;
    }
    if (total > 25) return fail(req, .validation_exception, "Too many items requested for the BatchWriteItem call (max 25).");

    var it2 = ri.object.iterator();
    while (it2.next()) |e| {
        const t = rt.registry.lookup(e.key_ptr.*) orelse return fail(req, .resource_not_found_exception, not_found_msg);
        for (e.value_ptr.*.array.items) |reqv| {
            if (reqv != .object) return fail(req, .validation_exception, "Write requests must be objects.");
            if (reqv.object.get("PutRequest")) |pr| {
                const iv = objField(pr, "Item") orelse return fail(req, .validation_exception, "PutRequest.Item is required.");
                const keyed = parseKeyed(a, iv, t.schema.key_schema) catch |err| return mapItemErr(req, err);
                var ctx: PlainPutCtx = .{ .item = keyed.item };
                _ = try t.mutate(keyed.key_enc, &ctx, plainPut);
            } else if (reqv.object.get("DeleteRequest")) |dr| {
                const kv = objField(dr, "Key") orelse return fail(req, .validation_exception, "DeleteRequest.Key is required.");
                const keyed = parseKeyed(a, kv, t.schema.key_schema) catch |err| return mapItemErr(req, err);
                var ctx: u8 = 0;
                _ = try t.mutate(keyed.key_enc, &ctx, plainDelete);
            } else return fail(req, .validation_exception, "Each write request must be a PutRequest or DeleteRequest.");
        }
    }

    var w = Writer.init(a);
    try w.beginObject();
    try w.writeKey("UnprocessedItems");
    try w.beginObject();
    try w.endObject();
    try w.endObject();
    return ok(w.finish());
}

// ---- TransactGetItems ----

pub fn transactGetItems(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    const ti = objField(req.body, "TransactItems") orelse return fail(req, .validation_exception, "TransactItems is required.");
    if (ti != .array) return fail(req, .validation_exception, "TransactItems must be a list.");
    if (ti.array.items.len > 100) return fail(req, .validation_exception, "Too many items in the TransactGetItems call (max 100).");

    var w = Writer.init(a);
    try w.beginObject();
    try w.writeKey("Responses");
    try w.beginArray();
    for (ti.array.items) |entry| {
        if (entry != .object) return fail(req, .validation_exception, "TransactItems entries must be objects.");
        const get = entry.object.get("Get") orelse return fail(req, .validation_exception, "Each TransactItems entry must contain a Get.");
        const tname = strField(get, "TableName") orelse return fail(req, .validation_exception, "TableName is required.");
        const t = rt.registry.lookup(tname) orelse return fail(req, .resource_not_found_exception, not_found_msg);
        const kv = objField(get, "Key") orelse return fail(req, .validation_exception, "Key is required.");
        const keyed = parseKeyed(a, kv, t.schema.key_schema) catch |err| return mapItemErr(req, err);
        try w.beginObject();
        if (t.getItem(keyed.key_enc)) |item| {
            if (!expired(t, item, rt)) {
                try w.writeKey("Item");
                writeProjected(&w, a, get, item) catch return fail(req, .validation_exception, "Invalid ProjectionExpression.");
            }
        }
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
    return ok(w.finish());
}

// ---- TransactWriteItems ----

const TxnKind = enum { put, update, delete, condition_check };

const TxnOp = struct {
    kind: TxnKind,
    table: *Table,
    key_enc: []u8,
    seed: Item,
    cond: ?*const parser.BoolExpr,
    prog: parser.UpdateProgram = .{},
    subst: Subst,
};

pub fn transactWriteItems(rt: *Runtime, req: *Request) anyerror!Response {
    const a = req.arena.allocator();
    const ti = objField(req.body, "TransactItems") orelse return fail(req, .validation_exception, "TransactItems is required.");
    if (ti != .array) return fail(req, .validation_exception, "TransactItems must be a list.");
    if (ti.array.items.len > 100) return fail(req, .validation_exception, "Too many items in the TransactWriteItems call (max 100).");

    // Idempotency: a replayed ClientRequestToken returns the prior response.
    const token = strField(req.body, "ClientRequestToken");
    if (token) |tk| {
        if (try rt.registry.txnCacheGet(a, tk)) |cached| return ok(cached);
    }

    var ops: std.ArrayListUnmanaged(TxnOp) = .empty;
    var err_resp: Response = undefined;
    for (ti.array.items) |entry| {
        if (entry != .object) return fail(req, .validation_exception, "TransactItems entries must be objects.");
        const op = parseTxnOp(rt, req, entry, &err_resp) catch return err_resp;
        try ops.append(a, op);
    }

    // Phase 1 — evaluate every condition against the current state.
    var failed_index: ?usize = null;
    for (ops.items, 0..) |op, i| {
        const current = op.table.getItem(op.key_enc);
        if (op.cond) |cnd| {
            const passed = eval.evalBool(a, cnd, current, &op.subst) catch
                return fail(req, .validation_exception, "A ConditionExpression references undefined names or values.");
            if (!passed) {
                failed_index = i;
                break;
            }
        }
    }
    if (failed_index) |fi| return cancelTransaction(a, ops.items.len, fi);

    // Phase 2 — apply all mutations in order.
    for (ops.items) |op| {
        switch (op.kind) {
            .condition_check => {},
            .put => {
                var ctx: PlainPutCtx = .{ .item = op.seed };
                _ = try op.table.mutate(op.key_enc, &ctx, plainPut);
            },
            .delete => {
                var ctx: u8 = 0;
                _ = try op.table.mutate(op.key_enc, &ctx, plainDelete);
            },
            .update => {
                var ctx: UpdateCtx = .{ .cond = null, .prog = op.prog, .subst = &op.subst, .scratch = a, .seed = op.seed };
                _ = try op.table.mutate(op.key_enc, &ctx, updateDecide);
            },
        }
    }

    if (token) |tk| try rt.registry.txnCachePut(tk, "{}");
    return ok("{}");
}

fn parseTxnOp(rt: *Runtime, req: *Request, entry: std.json.Value, err_out: *Response) !TxnOp {
    const a = req.arena.allocator();
    const Pair = struct { kind: TxnKind, field: []const u8 };
    const candidates = [_]Pair{
        .{ .kind = .put, .field = "Put" },
        .{ .kind = .update, .field = "Update" },
        .{ .kind = .delete, .field = "Delete" },
        .{ .kind = .condition_check, .field = "ConditionCheck" },
    };
    for (candidates) |cand| {
        const inner = entry.object.get(cand.field) orelse continue;
        const tname = strField(inner, "TableName") orelse return handled(req, err_out, .validation_exception, "TableName is required.");
        const t = rt.registry.lookup(tname) orelse return handled(req, err_out, .resource_not_found_exception, not_found_msg);

        const subst = buildSubst(a, inner) catch return handled(req, err_out, .validation_exception, "Invalid expression attributes.");
        const cond = compileCondition(a, inner, "ConditionExpression") catch return handled(req, err_out, .validation_exception, "Invalid ConditionExpression.");

        switch (cand.kind) {
            .put => {
                const iv = objField(inner, "Item") orelse return handled(req, err_out, .validation_exception, "Item is required.");
                const keyed = parseKeyed(a, iv, t.schema.key_schema) catch return handled(req, err_out, .validation_exception, "Invalid Item or key.");
                return .{ .kind = .put, .table = t, .key_enc = keyed.key_enc, .seed = keyed.item, .cond = cond, .subst = subst };
            },
            .delete, .condition_check => {
                const kv = objField(inner, "Key") orelse return handled(req, err_out, .validation_exception, "Key is required.");
                const keyed = parseKeyed(a, kv, t.schema.key_schema) catch return handled(req, err_out, .validation_exception, "Invalid Key.");
                if (cand.kind == .condition_check and cond == null) return handled(req, err_out, .validation_exception, "ConditionExpression is required for ConditionCheck.");
                return .{ .kind = cand.kind, .table = t, .key_enc = keyed.key_enc, .seed = keyed.item, .cond = cond, .subst = subst };
            },
            .update => {
                const kv = objField(inner, "Key") orelse return handled(req, err_out, .validation_exception, "Key is required.");
                const keyed = parseKeyed(a, kv, t.schema.key_schema) catch return handled(req, err_out, .validation_exception, "Invalid Key.");
                const ue = strField(inner, "UpdateExpression") orelse return handled(req, err_out, .validation_exception, "UpdateExpression is required.");
                const prog = parser.parseUpdate(a, ue) catch return handled(req, err_out, .validation_exception, "Invalid UpdateExpression.");
                return .{ .kind = .update, .table = t, .key_enc = keyed.key_enc, .seed = keyed.item, .cond = cond, .prog = prog, .subst = subst };
            },
        }
    }
    return handled(req, err_out, .validation_exception, "Each TransactItems entry must contain Put, Update, Delete, or ConditionCheck.");
}

fn handled(req: *const Request, err_out: *Response, code: errors.Code, msg: []const u8) error{HandledResponse} {
    err_out.* = fail(req, code, msg);
    return error.HandledResponse;
}

// TransactionCanceledException with per-item CancellationReasons.
fn cancelTransaction(a: std.mem.Allocator, count: usize, failed: usize) !Response {
    var w = Writer.init(a);
    try w.beginObject();
    try w.writeKey("__type");
    try w.writeString(errors.typeName(.transaction_canceled_exception));
    const msg = "Transaction cancelled, please refer cancellation reasons for specific reasons";
    try w.writeKey("message");
    try w.writeString(msg);
    try w.writeKey("Message");
    try w.writeString(msg);
    try w.writeKey("CancellationReasons");
    try w.beginArray();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try w.beginObject();
        try w.writeKey("Code");
        try w.writeString(if (i == failed) "ConditionalCheckFailed" else "None");
        if (i == failed) {
            try w.writeKey("Message");
            try w.writeString("The conditional request failed");
        }
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
    return .{ .status = errors.httpStatus(.transaction_canceled_exception), .body = w.finish() };
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

    fn makeTable(self: *TestEnv, schema: types.TableSchema) !*Table {
        return self.registry.createTable(schema);
    }

    fn call(self: *TestEnv, arena: *std.heap.ArenaAllocator, handler: anytype, json: []const u8) !Response {
        const body = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
        var req: Request = .{ .target = .put_item, .body = body, .request_id = [_]u8{'0'} ** 36, .arena = arena };
        return handler(self.rt, &req);
    }
};

fn simpleSchema(name: []const u8) types.TableSchema {
    return .{ .name = name, .key_schema = .{ .partition = .{ .name = "id", .kind = .S } } };
}

test "PutItem conditional: succeeds then fails on existing" {
    var env = try TestEnv.init();
    defer env.deinit();
    _ = try env.makeTable(simpleSchema("Users"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const json =
        \\{"TableName":"Users","Item":{"id":{"S":"u1"},"age":{"N":"42"}},
        \\"ConditionExpression":"attribute_not_exists(#id)","ExpressionAttributeNames":{"#id":"id"}}
    ;
    const ok1 = try env.call(&arena, putItem, json);
    try testing.expectEqual(@as(u16, 200), ok1.status);
    const fail1 = try env.call(&arena, putItem, json);
    try testing.expectEqual(@as(u16, 400), fail1.status);
    try testing.expect(std.mem.indexOf(u8, fail1.body, "ConditionalCheckFailedException") != null);
}

test "UpdateItem increments a counter from nothing" {
    var env = try TestEnv.init();
    defer env.deinit();
    _ = try env.makeTable(simpleSchema("Counters"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const json =
        \\{"TableName":"Counters","Key":{"id":{"S":"c1"}},
        \\"UpdateExpression":"SET cnt = if_not_exists(cnt, :z) + :one",
        \\"ExpressionAttributeValues":{":z":{"N":"0"},":one":{"N":"1"}},"ReturnValues":"UPDATED_NEW"}
    ;
    const r1 = try env.call(&arena, updateItem, json);
    try testing.expectEqual(@as(u16, 200), r1.status);
    try testing.expect(std.mem.indexOf(u8, r1.body, "\"cnt\":{\"N\":\"1\"}") != null);
    const r2 = try env.call(&arena, updateItem, json);
    try testing.expect(std.mem.indexOf(u8, r2.body, "\"cnt\":{\"N\":\"2\"}") != null);
}

test "GetItem honors TTL expiry" {
    var env = try TestEnv.init();
    defer env.deinit();
    const t = try env.makeTable(simpleSchema("Sessions"));
    try env.registry.updateTtl(t, true, "exp");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try env.call(&arena, putItem,
        \\{"TableName":"Sessions","Item":{"id":{"S":"s1"},"exp":{"N":"1"}}}
    );
    const got = try env.call(&arena, getItem, "{\"TableName\":\"Sessions\",\"Key\":{\"id\":{\"S\":\"s1\"}}}");
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"Item\"") == null);
}

test "Query returns only the matching partition" {
    var env = try TestEnv.init();
    defer env.deinit();
    const schema: types.TableSchema = .{
        .name = "Events",
        .key_schema = .{ .partition = .{ .name = "pk", .kind = .S }, .sort = .{ .name = "sk", .kind = .N } },
    };
    _ = try env.makeTable(schema);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    for ([_][]const u8{ "a", "a", "b" }, [_][]const u8{ "1", "2", "1" }) |pk, sk| {
        const j = try std.fmt.allocPrint(arena.allocator(),
            \\{{"TableName":"Events","Item":{{"pk":{{"S":"{s}"}},"sk":{{"N":"{s}"}}}}}}
        , .{ pk, sk });
        _ = try env.call(&arena, putItem, j);
    }
    const q = try env.call(&arena, query,
        \\{"TableName":"Events","KeyConditionExpression":"pk = :p","ExpressionAttributeValues":{":p":{"S":"a"}}}
    );
    try testing.expectEqual(@as(u16, 200), q.status);
    try testing.expect(std.mem.indexOf(u8, q.body, "\"Count\":2") != null);
}

test "Scan returns all, FilterExpression narrows" {
    var env = try TestEnv.init();
    defer env.deinit();
    _ = try env.makeTable(simpleSchema("Items"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (0..5) |i| {
        const j = try std.fmt.allocPrint(arena.allocator(),
            \\{{"TableName":"Items","Item":{{"id":{{"S":"i{d}"}},"n":{{"N":"{d}"}}}}}}
        , .{ i, i });
        _ = try env.call(&arena, putItem, j);
    }
    const all = try env.call(&arena, scan, "{\"TableName\":\"Items\"}");
    try testing.expect(std.mem.indexOf(u8, all.body, "\"Count\":5") != null);
    const filtered = try env.call(&arena, scan,
        \\{"TableName":"Items","FilterExpression":"n >= :t","ExpressionAttributeValues":{":t":{"N":"3"}}}
    );
    try testing.expect(std.mem.indexOf(u8, filtered.body, "\"Count\":2") != null);
}

test "Scan paginates with Limit and LastEvaluatedKey" {
    var env = try TestEnv.init();
    defer env.deinit();
    _ = try env.makeTable(simpleSchema("Big"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (0..10) |i| {
        const j = try std.fmt.allocPrint(arena.allocator(),
            \\{{"TableName":"Big","Item":{{"id":{{"S":"k{d:0>2}"}}}}}}
        , .{i});
        _ = try env.call(&arena, putItem, j);
    }
    var seen: usize = 0;
    var pages: usize = 0;
    var esk: ?[]const u8 = null;
    while (true) {
        const body = if (esk) |e| try std.fmt.allocPrint(arena.allocator(),
            \\{{"TableName":"Big","Limit":3,"ExclusiveStartKey":{s}}}
        , .{e}) else "{\"TableName\":\"Big\",\"Limit\":3}";
        const resp = try env.call(&arena, scan, body);
        pages += 1;
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), resp.body, .{});
        seen += @intCast(parsed.object.get("Count").?.integer);
        const lek = std.mem.indexOf(u8, resp.body, "\"LastEvaluatedKey\":");
        if (lek == null) break;
        const start = lek.? + "\"LastEvaluatedKey\":".len;
        // extract the JSON object value (single nesting level)
        var depth: usize = 0;
        var end = start;
        for (resp.body[start..], start..) |ch, i| {
            if (ch == '{') depth += 1;
            if (ch == '}') {
                depth -= 1;
                if (depth == 0) {
                    end = i + 1;
                    break;
                }
            }
        }
        esk = try arena.allocator().dupe(u8, resp.body[start..end]);
    }
    try testing.expectEqual(@as(usize, 10), seen);
    try testing.expectEqual(@as(usize, 4), pages);
}

test "ConsistentRead accepted as no-op" {
    var env = try TestEnv.init();
    defer env.deinit();
    _ = try env.makeTable(simpleSchema("CRead"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try env.call(&arena, putItem, "{\"TableName\":\"CRead\",\"Item\":{\"id\":{\"S\":\"x\"}}}");
    const got = try env.call(&arena, getItem, "{\"TableName\":\"CRead\",\"Key\":{\"id\":{\"S\":\"x\"}},\"ConsistentRead\":true}");
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"Item\"") != null);
}

test "BatchGetItem returns all 50" {
    var env = try TestEnv.init();
    defer env.deinit();
    const t = try env.makeTable(simpleSchema("Bget"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ta = t.arena.allocator();
    for (0..50) |i| {
        var item: Item = .{};
        try item.attrs.put(ta, "id", .{ .S = try std.fmt.allocPrint(ta, "k{d}", .{i}) });
        _ = try t.putItem(item, false);
    }
    var keys: std.ArrayListUnmanaged(u8) = .empty;
    for (0..50) |i| {
        if (i != 0) try keys.append(a, ',');
        try keys.appendSlice(a, try std.fmt.allocPrint(a, "{{\"id\":{{\"S\":\"k{d}\"}}}}", .{i}));
    }
    const body = try std.fmt.allocPrint(a, "{{\"RequestItems\":{{\"Bget\":{{\"Keys\":[{s}]}}}}}}", .{keys.items});
    const resp = try env.call(&arena, batchGetItem, body);
    try testing.expectEqual(@as(u16, 200), resp.status);
    var idx: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, resp.body, idx, "\"id\":")) |p| {
        count += 1;
        idx = p + 5;
    }
    try testing.expectEqual(@as(usize, 50), count);
}

test "BatchWriteItem of 25 raises count by 25" {
    var env = try TestEnv.init();
    defer env.deinit();
    const t = try env.makeTable(simpleSchema("Bwrite"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var reqs: std.ArrayListUnmanaged(u8) = .empty;
    for (0..25) |i| {
        if (i != 0) try reqs.append(a, ',');
        try reqs.appendSlice(a, try std.fmt.allocPrint(a, "{{\"PutRequest\":{{\"Item\":{{\"id\":{{\"S\":\"k{d}\"}}}}}}}}", .{i}));
    }
    const body = try std.fmt.allocPrint(a, "{{\"RequestItems\":{{\"Bwrite\":[{s}]}}}}", .{reqs.items});
    const resp = try env.call(&arena, batchWriteItem, body);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqual(@as(u64, 25), t.count());
}

test "TransactWrite aborts whole batch when a condition fails" {
    var env = try TestEnv.init();
    defer env.deinit();
    const t = try env.makeTable(simpleSchema("Txn"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // seed "b" so the attribute_not_exists condition on it fails
    {
        const ta = t.arena.allocator();
        var item: Item = .{};
        try item.attrs.put(ta, "id", .{ .S = "b" });
        _ = try t.putItem(item, false);
    }
    const body =
        \\{"TransactItems":[
        \\{"Put":{"TableName":"Txn","Item":{"id":{"S":"a"}}}},
        \\{"Put":{"TableName":"Txn","Item":{"id":{"S":"b"}},"ConditionExpression":"attribute_not_exists(id)"}},
        \\{"Put":{"TableName":"Txn","Item":{"id":{"S":"c"}}}}]}
    ;
    const resp = try env.call(&arena, transactWriteItems, body);
    try testing.expectEqual(@as(u16, 400), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "TransactionCanceledException") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "ConditionalCheckFailed") != null);
    // item "a" must not have been applied
    const enc = try key.encode(arena.allocator(), .{ .kind = .S, .bytes = "a" }, null);
    try testing.expect(t.getItem(enc) == null);
}

test "TransactWrite idempotent on repeated ClientRequestToken" {
    var env = try TestEnv.init();
    defer env.deinit();
    const t = try env.makeTable(simpleSchema("Idem"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body =
        \\{"ClientRequestToken":"tok-1","TransactItems":[
        \\{"Put":{"TableName":"Idem","Item":{"id":{"S":"x"}}}}]}
    ;
    const r1 = try env.call(&arena, transactWriteItems, body);
    try testing.expectEqual(@as(u16, 200), r1.status);
    const enc = try key.encode(arena.allocator(), .{ .kind = .S, .bytes = "x" }, null);
    _ = try t.deleteItem(enc, false);
    // replay: returns cached response and does NOT re-create the item
    const r2 = try env.call(&arena, transactWriteItems, body);
    try testing.expectEqual(@as(u16, 200), r2.status);
    try testing.expect(t.getItem(enc) == null);
}
