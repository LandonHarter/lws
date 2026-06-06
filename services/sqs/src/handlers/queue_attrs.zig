const std = @import("std");
const dispatch = @import("../wire/dispatch.zig");
const envelope = @import("../wire/envelope.zig");
const handler = @import("../wire/handler.zig");
const json_proto = @import("../wire/json_proto.zig");
const query_proto = @import("../wire/query_proto.zig");
const Runtime = @import("../runtime.zig").Runtime;
const errors = @import("../errors.zig");
const attrs = @import("../attrs.zig");
const config = @import("config");
const arn = @import("../arn.zig");
const queue = @import("../queue.zig");

const Request = envelope.Request;
const Response = handler.Response;

pub fn register(gpa: std.mem.Allocator) !void {
    try dispatch.table.register(gpa, "GetQueueUrl", getQueueUrl);
    try dispatch.table.register(gpa, "GetQueueAttributes", getQueueAttributes);
    try dispatch.table.register(gpa, "SetQueueAttributes", setQueueAttributes);
    try dispatch.table.register(gpa, "PurgeQueue", purgeQueue);
    try dispatch.table.register(gpa, "ListDeadLetterSourceQueues", listDeadLetterSourceQueues);
}

fn errResp(rt: *Runtime, req: *const Request, code: errors.Code) Response {
    return handler.renderError(rt, req, code, errors.defaultMessage(code));
}

fn mapParamErr(rt: *Runtime, req: *const Request, err: anyerror) Response {
    return switch (err) {
        error.MissingQueueName, error.MissingQueueUrl => errResp(rt, req, .missing_required_parameter),
        else => errResp(rt, req, .invalid_parameter_value),
    };
}

fn mapMutationErr(rt: *Runtime, req: *const Request, err: anyerror) Response {
    return switch (err) {
        error.QueueDoesNotExist => errResp(rt, req, .queue_does_not_exist),
        error.InvalidAttributeName => errResp(rt, req, .invalid_attribute_name),
        error.InvalidAttributeValue => errResp(rt, req, .invalid_attribute_value),
        error.PurgeInProgress => errResp(rt, req, .purge_queue_in_progress),
        else => errResp(rt, req, .internal_error),
    };
}

fn queueUrl(arena: std.mem.Allocator, rt: *Runtime, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "http://{s}/{s}/{s}", .{ rt.host, rt.account, name });
}

fn queueArn(arena: std.mem.Allocator, rt: *Runtime, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "arn:aws:sqs:{s}:{s}:{s}", .{ rt.region, rt.account, name });
}

// ---- param decoding ----

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn parseQueueUrlParam(req: *const Request) ![]const u8 {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            return jsonString(root.object, "QueueUrl") orelse return error.MissingQueueUrl;
        },
        .query => return (try query_proto.getScalar(req.body, arena, "QueueUrl")) orelse return error.MissingQueueUrl,
    }
}

fn parseQueueNameParam(req: *const Request) ![]const u8 {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            return jsonString(root.object, "QueueName") orelse return error.MissingQueueName;
        },
        .query => return (try query_proto.getScalar(req.body, arena, "QueueName")) orelse return error.MissingQueueName,
    }
}

// AttributeNames list (JSON array or query AttributeName.N).
fn parseAttributeNames(req: *const Request) ![]const []const u8 {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const v = root.object.get("AttributeNames") orelse return &.{};
            if (v != .array) return error.InvalidParamValue;
            var out = try arena.alloc([]const u8, v.array.items.len);
            for (v.array.items, 0..) |item, i| {
                if (item != .string) return error.InvalidParamValue;
                out[i] = item.string;
            }
            return out;
        },
        .query => return query_proto.getIndexedList(req.body, arena, "AttributeName.{i}"),
    }
}

// Attributes map for SetQueueAttributes (JSON object or query Attribute.N.Name/Value).
fn parseAttributesMap(req: *const Request) !queue.TagMap {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            var map: queue.TagMap = .empty;
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const v = root.object.get("Attributes") orelse return map;
            if (v != .object) return error.InvalidParamValue;
            var it = v.object.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* != .string) return error.InvalidParamValue;
                try map.put(arena, e.key_ptr.*, e.value_ptr.*.string);
            }
            return map;
        },
        .query => return query_proto.getIndexedMap(req.body, arena, "Attribute"),
    }
}

// ---- attribute serialization ----

fn valueStr(arena: std.mem.Allocator, v: config.Value) ![]const u8 {
    return switch (v) {
        .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .boolean => |b| if (b) "true" else "false",
        .string => |s| s,
        .json => |j| j,
    };
}

const computed_names = [_][]const u8{
    "QueueArn",
    "CreatedTimestamp",
    "LastModifiedTimestamp",
    "ApproximateNumberOfMessages",
    "ApproximateNumberOfMessagesNotVisible",
    "ApproximateNumberOfMessagesDelayed",
};

fn isComputed(name: []const u8) bool {
    for (computed_names) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

fn storeCount(q: *queue.Queue, comptime which: enum { visible, in_flight, delayed }) u64 {
    const s = q.store orelse return 0;
    return switch (which) {
        .visible => s.vtable.count_visible(s.ctx),
        .in_flight => s.vtable.count_in_flight(s.ctx),
        .delayed => s.vtable.count_delayed(s.ctx),
    };
}

// Resolves a computed read-only attr to its string value. Caller must have
// checked isComputed first.
fn computedValue(arena: std.mem.Allocator, rt: *Runtime, q: *queue.Queue, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "QueueArn")) return queueArn(arena, rt, q.name);
    if (std.mem.eql(u8, name, "CreatedTimestamp")) return std.fmt.allocPrint(arena, "{d}", .{q.created_at});
    if (std.mem.eql(u8, name, "LastModifiedTimestamp")) return std.fmt.allocPrint(arena, "{d}", .{q.last_modified_at});
    if (std.mem.eql(u8, name, "ApproximateNumberOfMessages")) return std.fmt.allocPrint(arena, "{d}", .{storeCount(q, .visible)});
    if (std.mem.eql(u8, name, "ApproximateNumberOfMessagesNotVisible")) return std.fmt.allocPrint(arena, "{d}", .{storeCount(q, .in_flight)});
    if (std.mem.eql(u8, name, "ApproximateNumberOfMessagesDelayed")) return std.fmt.allocPrint(arena, "{d}", .{storeCount(q, .delayed)});
    unreachable;
}

const Pair = struct { name: []const u8, value: []const u8 };

fn collectAttrs(arena: std.mem.Allocator, rt: *Runtime, q: *queue.Queue, names: []const []const u8) ![]Pair {
    var want_all = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "All")) want_all = true;
    }

    var out: std.ArrayList(Pair) = .empty;

    if (want_all) {
        var it = q.attributes.iterator();
        while (it.next()) |e| {
            try out.append(arena, .{ .name = e.key_ptr.*, .value = try valueStr(arena, e.value_ptr.*) });
        }
        for (computed_names) |c| {
            try out.append(arena, .{ .name = c, .value = try computedValue(arena, rt, q, c) });
        }
        return out.items;
    }

    for (names) |n| {
        if (isComputed(n)) {
            try out.append(arena, .{ .name = n, .value = try computedValue(arena, rt, q, n) });
        } else if (q.attributes.get(n)) |v| {
            try out.append(arena, .{ .name = n, .value = try valueStr(arena, v) });
        }
        // valid-but-unset attrs (e.g. KmsMasterKeyId with no default) are omitted, matching AWS.
    }
    return out.items;
}

// ---- handlers ----

fn getQueueUrl(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const name = parseQueueNameParam(req) catch |e| return mapParamErr(rt, req, e);
    if (rt.registry.get(name) == null) return errResp(rt, req, .queue_does_not_exist);
    const url = try queueUrl(arena, rt, name);

    switch (req.protocol) {
        .json => {
            var w = json_proto.Writer.init(arena);
            try w.beginObject();
            try w.writeKey("QueueUrl");
            try w.writeString(url);
            try w.endObject();
            return jsonOk(w.finish());
        },
        .query => {
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("GetQueueUrlResponse");
            try x.open("GetQueueUrlResult");
            try x.element("QueueUrl", url);
            try x.close("GetQueueUrlResult");
            try writeMetadata(&x, req);
            try x.close("GetQueueUrlResponse");
            return xmlOk(x.finish());
        },
    }
}

fn getQueueAttributes(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const url = parseQueueUrlParam(req) catch |e| return mapParamErr(rt, req, e);
    const names = parseAttributeNames(req) catch |e| return mapParamErr(rt, req, e);
    const name = arn.parseQueueUrl(url) catch return errResp(rt, req, .invalid_parameter_value);
    const q = rt.registry.get(name) orelse return errResp(rt, req, .queue_does_not_exist);

    // Reject unknown attr names unless "All" requested.
    var want_all = false;
    for (names) |n| if (std.mem.eql(u8, n, "All")) {
        want_all = true;
    };
    if (!want_all) {
        for (names) |n| {
            if (config.lookup(&attrs.queue_attrs, n) == null) return errResp(rt, req, .invalid_attribute_name);
        }
    }

    const pairs = try collectAttrs(arena, rt, q, names);

    switch (req.protocol) {
        .json => {
            var w = json_proto.Writer.init(arena);
            try w.beginObject();
            try w.writeKey("Attributes");
            try w.beginObject();
            for (pairs) |p| {
                try w.writeKey(p.name);
                try w.writeString(p.value);
            }
            try w.endObject();
            try w.endObject();
            return jsonOk(w.finish());
        },
        .query => {
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("GetQueueAttributesResponse");
            try x.open("GetQueueAttributesResult");
            for (pairs) |p| {
                try x.open("Attribute");
                try x.element("Name", p.name);
                try x.element("Value", p.value);
                try x.close("Attribute");
            }
            try x.close("GetQueueAttributesResult");
            try writeMetadata(&x, req);
            try x.close("GetQueueAttributesResponse");
            return xmlOk(x.finish());
        },
    }
}

fn setQueueAttributes(rt: *Runtime, req: *const Request) anyerror!Response {
    const url = parseQueueUrlParam(req) catch |e| return mapParamErr(rt, req, e);
    const map = parseAttributesMap(req) catch |e| return mapParamErr(rt, req, e);
    const name = arn.parseQueueUrl(url) catch return errResp(rt, req, .invalid_parameter_value);
    rt.registry.setAttributes(name, &map) catch |e| return mapMutationErr(rt, req, e);

    switch (req.protocol) {
        .json => return jsonOk("{}"),
        .query => {
            const arena = req.arena.allocator();
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("SetQueueAttributesResponse");
            try writeMetadata(&x, req);
            try x.close("SetQueueAttributesResponse");
            return xmlOk(x.finish());
        },
    }
}

fn purgeQueue(rt: *Runtime, req: *const Request) anyerror!Response {
    const url = parseQueueUrlParam(req) catch |e| return mapParamErr(rt, req, e);
    const name = arn.parseQueueUrl(url) catch return errResp(rt, req, .invalid_parameter_value);
    rt.registry.purge(name) catch |e| return mapMutationErr(rt, req, e);

    switch (req.protocol) {
        .json => return jsonOk("{}"),
        .query => {
            const arena = req.arena.allocator();
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("PurgeQueueResponse");
            try writeMetadata(&x, req);
            try x.close("PurgeQueueResponse");
            return xmlOk(x.finish());
        },
    }
}

fn listDeadLetterSourceQueues(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const url = parseQueueUrlParam(req) catch |e| return mapParamErr(rt, req, e);
    const name = arn.parseQueueUrl(url) catch return errResp(rt, req, .invalid_parameter_value);
    if (rt.registry.get(name) == null) return errResp(rt, req, .queue_does_not_exist);

    const target_arn = try queueArn(arena, rt, name);
    const names = rt.registry.dlqSourceNames(arena, target_arn) catch return errResp(rt, req, .internal_error);

    var urls = try arena.alloc([]const u8, names.len);
    for (names, 0..) |n, i| urls[i] = try queueUrl(arena, rt, n);

    switch (req.protocol) {
        .json => {
            var w = json_proto.Writer.init(arena);
            try w.beginObject();
            try w.writeKey("queueUrls");
            try w.beginArray();
            for (urls) |u| try w.writeString(u);
            try w.endArray();
            try w.endObject();
            return jsonOk(w.finish());
        },
        .query => {
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("ListDeadLetterSourceQueuesResponse");
            try x.open("ListDeadLetterSourceQueuesResult");
            for (urls) |u| try x.element("QueueUrl", u);
            try x.close("ListDeadLetterSourceQueuesResult");
            try writeMetadata(&x, req);
            try x.close("ListDeadLetterSourceQueuesResponse");
            return xmlOk(x.finish());
        },
    }
}

fn writeMetadata(x: *query_proto.XmlWriter, req: *const Request) !void {
    try x.open("ResponseMetadata");
    try x.element("RequestId", req.request_id[0..]);
    try x.close("ResponseMetadata");
}

fn jsonOk(body: []const u8) Response {
    return .{ .status = 200, .body = body, .content_type = handler.json_content_type };
}

fn xmlOk(body: []const u8) Response {
    return .{ .status = 200, .body = body, .content_type = handler.xml_content_type };
}
