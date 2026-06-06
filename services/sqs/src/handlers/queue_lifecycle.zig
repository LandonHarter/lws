const std = @import("std");
const dispatch = @import("../wire/dispatch.zig");
const envelope = @import("../wire/envelope.zig");
const handler = @import("../wire/handler.zig");
const json_proto = @import("../wire/json_proto.zig");
const query_proto = @import("../wire/query_proto.zig");
const Runtime = @import("../runtime.zig").Runtime;
const errors = @import("../errors.zig");
const queue = @import("../queue.zig");

const Request = envelope.Request;
const Response = handler.Response;

pub fn register(gpa: std.mem.Allocator) !void {
    try dispatch.table.register(gpa, "CreateQueue", createQueue);
    try dispatch.table.register(gpa, "DeleteQueue", deleteQueue);
    try dispatch.table.register(gpa, "ListQueues", listQueues);
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

fn mapRegistryErr(rt: *Runtime, req: *const Request, err: anyerror) Response {
    return switch (err) {
        error.QueueNameExists => errResp(rt, req, .queue_name_exists),
        error.QueueDeletedRecently => errResp(rt, req, .queue_deleted_recently),
        error.QueueDoesNotExist => errResp(rt, req, .queue_does_not_exist),
        error.InvalidQueueName => errResp(rt, req, .invalid_parameter_value),
        error.InvalidAttributeName => errResp(rt, req, .invalid_attribute_name),
        error.InvalidAttributeValue => errResp(rt, req, .invalid_attribute_value),
        else => errResp(rt, req, .internal_error),
    };
}

fn queueUrl(arena: std.mem.Allocator, rt: *Runtime, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "http://{s}/{s}/{s}", .{ rt.host, rt.account, name });
}

// ---- param decoding ----

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonStringMap(arena: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !queue.TagMap {
    var map: queue.TagMap = .empty;
    const v = obj.get(key) orelse return map;
    if (v != .object) return error.InvalidParamValue;
    var it = v.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .string) return error.InvalidParamValue;
        try map.put(arena, e.key_ptr.*, e.value_ptr.*.string);
    }
    return map;
}

fn queryTagMap(body: []const u8, arena: std.mem.Allocator) !queue.TagMap {
    var map: queue.TagMap = .empty;
    var idx: usize = 1;
    while (true) : (idx += 1) {
        var kb: [256]u8 = undefined;
        var vb: [256]u8 = undefined;
        const key_name = std.fmt.bufPrint(&kb, "Tag.{d}.Key", .{idx}) catch break;
        const val_name = std.fmt.bufPrint(&vb, "Tag.{d}.Value", .{idx}) catch break;
        const k = try query_proto.getScalar(body, arena, key_name);
        if (k == null) break;
        const val = (try query_proto.getScalar(body, arena, val_name)) orelse "";
        try map.put(arena, k.?, val);
    }
    return map;
}

const CreateParams = struct {
    name: []const u8,
    attrs: queue.TagMap,
    tags: queue.TagMap,
};

fn parseCreate(req: *const Request) !CreateParams {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            const name = jsonString(obj, "QueueName") orelse return error.MissingQueueName;
            return .{
                .name = name,
                .attrs = try jsonStringMap(arena, obj, "Attributes"),
                .tags = try jsonStringMap(arena, obj, "tags"),
            };
        },
        .query => {
            const name = (try query_proto.getScalar(req.body, arena, "QueueName")) orelse return error.MissingQueueName;
            return .{
                .name = name,
                .attrs = try query_proto.getIndexedMap(req.body, arena, "Attribute"),
                .tags = try queryTagMap(req.body, arena),
            };
        },
    }
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

const ListParams = struct {
    prefix: ?[]const u8 = null,
    max_results: ?usize = null,
    next_token: ?[]const u8 = null,
};

fn parseList(req: *const Request) !ListParams {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            var max: ?usize = null;
            if (obj.get("MaxResults")) |v| switch (v) {
                .integer => |n| if (n > 0) {
                    max = @intCast(n);
                },
                .string => |s| {
                    max = std.fmt.parseInt(usize, s, 10) catch null;
                },
                else => {},
            };
            return .{
                .prefix = jsonString(obj, "QueueNamePrefix"),
                .max_results = max,
                .next_token = jsonString(obj, "NextToken"),
            };
        },
        .query => {
            var max: ?usize = null;
            if (try query_proto.getScalar(req.body, arena, "MaxResults")) |s| {
                max = std.fmt.parseInt(usize, s, 10) catch null;
            }
            return .{
                .prefix = try query_proto.getScalar(req.body, arena, "QueueNamePrefix"),
                .max_results = max,
                .next_token = try query_proto.getScalar(req.body, arena, "NextToken"),
            };
        },
    }
}

// ---- handlers ----

fn createQueue(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const p = parseCreate(req) catch |e| return mapParamErr(rt, req, e);
    const q = rt.registry.create(p.name, &p.attrs, &p.tags) catch |e| return mapRegistryErr(rt, req, e);
    const url = try queueUrl(arena, rt, q.name);

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
            try x.open("CreateQueueResponse");
            try x.open("CreateQueueResult");
            try x.element("QueueUrl", url);
            try x.close("CreateQueueResult");
            try writeMetadata(&x, req);
            try x.close("CreateQueueResponse");
            return xmlOk(x.finish());
        },
    }
}

fn deleteQueue(rt: *Runtime, req: *const Request) anyerror!Response {
    const url = parseQueueUrlParam(req) catch |e| return mapParamErr(rt, req, e);
    const name = @import("../arn.zig").parseQueueUrl(url) catch return errResp(rt, req, .invalid_parameter_value);
    rt.registry.delete(name) catch |e| return mapRegistryErr(rt, req, e);

    switch (req.protocol) {
        .json => return jsonOk("{}"),
        .query => {
            const arena = req.arena.allocator();
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("DeleteQueueResponse");
            try writeMetadata(&x, req);
            try x.close("DeleteQueueResponse");
            return xmlOk(x.finish());
        },
    }
}

fn listQueues(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const p = parseList(req) catch |e| return mapParamErr(rt, req, e);

    const names = rt.registry.listNames(arena, p.prefix) catch return errResp(rt, req, .internal_error);
    const start = blk: {
        const t = p.next_token orelse break :blk @as(usize, 0);
        break :blk std.fmt.parseInt(usize, t, 10) catch 0;
    };
    const clamped_start = @min(start, names.len);
    const max = p.max_results orelse names.len;
    const end = @min(clamped_start + max, names.len);
    const page = names[clamped_start..end];
    const next: ?usize = if (end < names.len) end else null;

    var urls = try arena.alloc([]const u8, page.len);
    for (page, 0..) |name, i| urls[i] = try queueUrl(arena, rt, name);

    switch (req.protocol) {
        .json => {
            var w = json_proto.Writer.init(arena);
            try w.beginObject();
            if (urls.len > 0) {
                try w.writeKey("QueueUrls");
                try w.beginArray();
                for (urls) |u| try w.writeString(u);
                try w.endArray();
            }
            if (next) |n| {
                try w.writeKey("NextToken");
                try w.writeString(try std.fmt.allocPrint(arena, "{d}", .{n}));
            }
            try w.endObject();
            return jsonOk(w.finish());
        },
        .query => {
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("ListQueuesResponse");
            try x.open("ListQueuesResult");
            for (urls) |u| try x.element("QueueUrl", u);
            if (next) |n| try x.element("NextToken", try std.fmt.allocPrint(arena, "{d}", .{n}));
            try x.close("ListQueuesResult");
            try writeMetadata(&x, req);
            try x.close("ListQueuesResponse");
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
