const std = @import("std");
const json_proto = @import("wire/json_proto.zig");

pub const Error = error{ DuplicateLabel, StatementNotFound, InvalidPolicy };

const default_version = "2012-10-17";

pub const NewStatement = struct {
    sid: []const u8,
    principal_arns: []const []const u8,
    action_arns: []const []const u8,
    resource: []const u8,
};

// Re-emits a parsed JSON value verbatim into the writer. Used to preserve
// statements (and unknown fields) that AddPermission/RemovePermission don't own.
fn writeValue(w: *json_proto.Writer, v: std.json.Value) !void {
    switch (v) {
        .null => try w.writeRaw("null"),
        .bool => |b| try w.writeBool(b),
        .integer => |n| try w.writeInt(n),
        .float => |f| {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
            try w.writeRaw(s);
        },
        .number_string => |s| try w.writeRaw(s),
        .string => |s| try w.writeString(s),
        .array => |arr| {
            try w.beginArray();
            for (arr.items) |item| try writeValue(w, item);
            try w.endArray();
        },
        .object => |obj| {
            try w.beginObject();
            var it = obj.iterator();
            while (it.next()) |e| {
                try w.writeKey(e.key_ptr.*);
                try writeValue(w, e.value_ptr.*);
            }
            try w.endObject();
        },
    }
}

// Normalizes the "Statement" field (array | single object | absent) to a slice.
fn statementItems(arena: std.mem.Allocator, root: std.json.Value) ![]std.json.Value {
    if (root != .object) return Error.InvalidPolicy;
    const sv = root.object.get("Statement") orelse return &.{};
    return switch (sv) {
        .array => |arr| arr.items,
        .object => blk: {
            const one = try arena.alloc(std.json.Value, 1);
            one[0] = sv;
            break :blk one;
        },
        else => Error.InvalidPolicy,
    };
}

fn stmtSid(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    const s = v.object.get("Sid") orelse return null;
    return switch (s) {
        .string => |str| str,
        else => null,
    };
}

fn objString(root: std.json.Value, key: []const u8, fallback: []const u8) []const u8 {
    if (root != .object) return fallback;
    const v = root.object.get(key) orelse return fallback;
    return switch (v) {
        .string => |s| s,
        else => fallback,
    };
}

fn writeNewStatement(w: *json_proto.Writer, stmt: NewStatement) !void {
    try w.beginObject();
    try w.writeKey("Sid");
    try w.writeString(stmt.sid);
    try w.writeKey("Effect");
    try w.writeString("Allow");
    try w.writeKey("Principal");
    try w.beginObject();
    try w.writeKey("AWS");
    try w.beginArray();
    for (stmt.principal_arns) |arn| try w.writeString(arn);
    try w.endArray();
    try w.endObject();
    try w.writeKey("Action");
    try w.beginArray();
    for (stmt.action_arns) |action| try w.writeString(action);
    try w.endArray();
    try w.writeKey("Resource");
    try w.writeString(stmt.resource);
    try w.endObject();
}

// Appends `stmt` to the policy in `existing` (null/empty -> a fresh policy),
// preserving any unrelated statements. Errors DuplicateLabel if a statement
// already uses stmt.sid as its Sid. Returns the new policy JSON in `arena`.
pub fn addStatement(
    arena: std.mem.Allocator,
    existing: ?[]const u8,
    policy_id: []const u8,
    stmt: NewStatement,
) ![]const u8 {
    var version: []const u8 = default_version;
    var id: []const u8 = policy_id;
    var prior: []std.json.Value = &.{};

    if (existing) |raw| {
        if (std.mem.trim(u8, raw, " \t\r\n").len > 0) {
            const root = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return Error.InvalidPolicy;
            version = objString(root, "Version", default_version);
            id = objString(root, "Id", policy_id);
            prior = try statementItems(arena, root);
            for (prior) |p| {
                if (stmtSid(p)) |sid| {
                    if (std.mem.eql(u8, sid, stmt.sid)) return Error.DuplicateLabel;
                }
            }
        }
    }

    var w = json_proto.Writer.init(arena);
    try w.beginObject();
    try w.writeKey("Version");
    try w.writeString(version);
    try w.writeKey("Id");
    try w.writeString(id);
    try w.writeKey("Statement");
    try w.beginArray();
    for (prior) |p| try writeValue(&w, p);
    try writeNewStatement(&w, stmt);
    try w.endArray();
    try w.endObject();
    return w.finish();
}

// Removes the statement whose Sid equals `label`. Returns the rewritten policy
// JSON, or null when no statements remain. Errors StatementNotFound if no
// matching statement exists.
pub fn removeStatement(
    arena: std.mem.Allocator,
    existing: []const u8,
    label: []const u8,
) !?[]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, existing, .{}) catch return Error.InvalidPolicy;
    const items = try statementItems(arena, root);

    var kept: std.ArrayList(std.json.Value) = .empty;
    var removed = false;
    for (items) |it| {
        if (stmtSid(it)) |sid| {
            if (std.mem.eql(u8, sid, label)) {
                removed = true;
                continue;
            }
        }
        try kept.append(arena, it);
    }
    if (!removed) return Error.StatementNotFound;
    if (kept.items.len == 0) return null;

    const version = objString(root, "Version", default_version);
    const id = objString(root, "Id", "");

    var w = json_proto.Writer.init(arena);
    try w.beginObject();
    try w.writeKey("Version");
    try w.writeString(version);
    if (id.len > 0) {
        try w.writeKey("Id");
        try w.writeString(id);
    }
    try w.writeKey("Statement");
    try w.beginArray();
    for (kept.items) |it| try writeValue(&w, it);
    try w.endArray();
    try w.endObject();
    return w.finish();
}

const testing = std.testing;

fn parse(arena: std.mem.Allocator, s: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, s, .{});
}

test "addStatement synthesizes a fresh policy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try addStatement(a, null, "arn:.../SQSDefaultPolicy", .{
        .sid = "dev-rw",
        .principal_arns = &.{"arn:aws:iam::111122223333:root"},
        .action_arns = &.{ "SQS:SendMessage", "SQS:ReceiveMessage" },
        .resource = "arn:aws:sqs:us-east-1:000000000000:q",
    });
    const root = try parse(a, out);
    try testing.expectEqualStrings(default_version, root.object.get("Version").?.string);
    try testing.expectEqualStrings("arn:.../SQSDefaultPolicy", root.object.get("Id").?.string);
    const stmts = root.object.get("Statement").?.array.items;
    try testing.expectEqual(@as(usize, 1), stmts.len);
    try testing.expectEqualStrings("dev-rw", stmts[0].object.get("Sid").?.string);
    try testing.expectEqualStrings("Allow", stmts[0].object.get("Effect").?.string);
    try testing.expectEqualStrings("SQS:SendMessage", stmts[0].object.get("Action").?.array.items[0].string);
}

test "addStatement appends and preserves prior statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try addStatement(a, null, "pid", .{
        .sid = "a",
        .principal_arns = &.{"arn:aws:iam::1:root"},
        .action_arns = &.{"SQS:SendMessage"},
        .resource = "res",
    });
    const second = try addStatement(a, first, "pid", .{
        .sid = "b",
        .principal_arns = &.{"arn:aws:iam::2:root"},
        .action_arns = &.{"SQS:ReceiveMessage"},
        .resource = "res",
    });
    const root = try parse(a, second);
    const stmts = root.object.get("Statement").?.array.items;
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expectEqualStrings("a", stmts[0].object.get("Sid").?.string);
    try testing.expectEqualStrings("b", stmts[1].object.get("Sid").?.string);
}

test "addStatement rejects duplicate label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try addStatement(a, null, "pid", .{
        .sid = "dup",
        .principal_arns = &.{"arn:aws:iam::1:root"},
        .action_arns = &.{"SQS:SendMessage"},
        .resource = "res",
    });
    try testing.expectError(Error.DuplicateLabel, addStatement(a, first, "pid", .{
        .sid = "dup",
        .principal_arns = &.{"arn:aws:iam::2:root"},
        .action_arns = &.{"SQS:ReceiveMessage"},
        .resource = "res",
    }));
}

test "removeStatement drops one and keeps others" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = try addStatement(a, null, "pid", .{
        .sid = "a",
        .principal_arns = &.{"arn:aws:iam::1:root"},
        .action_arns = &.{"SQS:SendMessage"},
        .resource = "res",
    });
    p = try addStatement(a, p, "pid", .{
        .sid = "b",
        .principal_arns = &.{"arn:aws:iam::2:root"},
        .action_arns = &.{"SQS:ReceiveMessage"},
        .resource = "res",
    });
    const next = (try removeStatement(a, p, "a")).?;
    const root = try parse(a, next);
    const stmts = root.object.get("Statement").?.array.items;
    try testing.expectEqual(@as(usize, 1), stmts.len);
    try testing.expectEqualStrings("b", stmts[0].object.get("Sid").?.string);
}

test "removeStatement returns null when last removed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try addStatement(a, null, "pid", .{
        .sid = "only",
        .principal_arns = &.{"arn:aws:iam::1:root"},
        .action_arns = &.{"SQS:SendMessage"},
        .resource = "res",
    });
    try testing.expect((try removeStatement(a, p, "only")) == null);
}

test "removeStatement errors on missing label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try addStatement(a, null, "pid", .{
        .sid = "only",
        .principal_arns = &.{"arn:aws:iam::1:root"},
        .action_arns = &.{"SQS:SendMessage"},
        .resource = "res",
    });
    try testing.expectError(Error.StatementNotFound, removeStatement(a, p, "nope"));
}

test "addStatement preserves unrelated fields in external policy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const external =
        \\{"Version":"2012-10-17","Id":"custom","Statement":[{"Sid":"ext","Effect":"Deny","Principal":"*","Action":"SQS:*","Resource":"res","Condition":{"StringEquals":{"k":"v"}}}]}
    ;
    const out = try addStatement(a, external, "pid", .{
        .sid = "new",
        .principal_arns = &.{"arn:aws:iam::1:root"},
        .action_arns = &.{"SQS:SendMessage"},
        .resource = "res",
    });
    const root = try parse(a, out);
    try testing.expectEqualStrings("custom", root.object.get("Id").?.string);
    const stmts = root.object.get("Statement").?.array.items;
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expectEqualStrings("ext", stmts[0].object.get("Sid").?.string);
    try testing.expectEqualStrings("Deny", stmts[0].object.get("Effect").?.string);
    try testing.expectEqualStrings("v", stmts[0].object.get("Condition").?.object.get("StringEquals").?.object.get("k").?.string);
}
