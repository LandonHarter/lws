const std = @import("std");
const dispatch = @import("../wire/dispatch.zig");
const envelope = @import("../wire/envelope.zig");
const handler = @import("../wire/handler.zig");
const json_proto = @import("../wire/json_proto.zig");
const query_proto = @import("../wire/query_proto.zig");
const Runtime = @import("../runtime.zig").Runtime;
const errors = @import("../errors.zig");
const arn = @import("../arn.zig");
const queue = @import("../queue.zig");

const Request = envelope.Request;
const Response = handler.Response;

const max_tags = 50;
const max_key_len = 128;
const max_value_len = 256;

pub fn register(gpa: std.mem.Allocator) !void {
    try dispatch.table.register(gpa, "TagQueue", tagQueue);
    try dispatch.table.register(gpa, "UntagQueue", untagQueue);
    try dispatch.table.register(gpa, "ListQueueTags", listQueueTags);
}

fn errResp(rt: *Runtime, req: *const Request, code: errors.Code) Response {
    return handler.renderError(rt, req, code, errors.defaultMessage(code));
}

fn mapParamErr(rt: *Runtime, req: *const Request, err: anyerror) Response {
    return switch (err) {
        error.MissingQueueUrl => errResp(rt, req, .missing_required_parameter),
        else => errResp(rt, req, .invalid_parameter_value),
    };
}

// ---- param decoding ----

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
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

const TagParams = struct { url: []const u8, tags: queue.TagMap };

fn parseTag(req: *const Request) !TagParams {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            const url = jsonString(obj, "QueueUrl") orelse return error.MissingQueueUrl;
            var map: queue.TagMap = .empty;
            if (obj.get("Tags")) |v| {
                if (v != .object) return error.InvalidParamValue;
                var it = v.object.iterator();
                while (it.next()) |e| {
                    if (e.value_ptr.* != .string) return error.InvalidParamValue;
                    try map.put(arena, e.key_ptr.*, e.value_ptr.*.string);
                }
            }
            return .{ .url = url, .tags = map };
        },
        .query => {
            const url = (try query_proto.getScalar(req.body, arena, "QueueUrl")) orelse return error.MissingQueueUrl;
            return .{ .url = url, .tags = try queryTagMap(req.body, arena) };
        },
    }
}

const UntagParams = struct { url: []const u8, keys: []const []const u8 };

fn parseUntag(req: *const Request) !UntagParams {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            const url = jsonString(obj, "QueueUrl") orelse return error.MissingQueueUrl;
            const v = obj.get("TagKeys") orelse return .{ .url = url, .keys = &.{} };
            if (v != .array) return error.InvalidParamValue;
            var out = try arena.alloc([]const u8, v.array.items.len);
            for (v.array.items, 0..) |item, i| {
                if (item != .string) return error.InvalidParamValue;
                out[i] = item.string;
            }
            return .{ .url = url, .keys = out };
        },
        .query => {
            const url = (try query_proto.getScalar(req.body, arena, "QueueUrl")) orelse return error.MissingQueueUrl;
            return .{ .url = url, .keys = try query_proto.getIndexedList(req.body, arena, "TagKey.{i}") };
        },
    }
}

// ---- validation ----

fn validCharset(s: []const u8) bool {
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or switch (c) {
            ' ', '_', '.', ':', '/', '=', '+', '-', '@' => true,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

fn validateTags(tags: *const queue.TagMap) bool {
    var it = tags.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const val = e.value_ptr.*;
        if (key.len < 1 or key.len > max_key_len) return false;
        if (val.len > max_value_len) return false;
        if (!validCharset(key) or !validCharset(val)) return false;
    }
    return true;
}

// ---- handlers ----

fn tagQueue(rt: *Runtime, req: *const Request) anyerror!Response {
    const p = parseTag(req) catch |e| return mapParamErr(rt, req, e);
    const name = arn.parseQueueUrl(p.url) catch return errResp(rt, req, .invalid_parameter_value);
    const q = rt.registry.get(name) orelse return errResp(rt, req, .queue_does_not_exist);

    if (!validateTags(&p.tags)) return errResp(rt, req, .invalid_parameter_value);

    // Combined tag count after merge must not exceed the limit.
    var combined = q.tags.count();
    var it = p.tags.iterator();
    while (it.next()) |e| {
        if (q.tags.get(e.key_ptr.*) == null) combined += 1;
    }
    if (combined > max_tags) return errResp(rt, req, .invalid_parameter_value);

    rt.registry.addTags(name, &p.tags) catch return errResp(rt, req, .internal_error);
    return emptyOk(rt, req, "TagQueue");
}

fn untagQueue(rt: *Runtime, req: *const Request) anyerror!Response {
    const p = parseUntag(req) catch |e| return mapParamErr(rt, req, e);
    const name = arn.parseQueueUrl(p.url) catch return errResp(rt, req, .invalid_parameter_value);
    if (rt.registry.get(name) == null) return errResp(rt, req, .queue_does_not_exist);

    rt.registry.removeTags(name, p.keys) catch return errResp(rt, req, .internal_error);
    return emptyOk(rt, req, "UntagQueue");
}

fn listQueueTags(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const p = parseTag(req) catch |e| return mapParamErr(rt, req, e);
    const name = arn.parseQueueUrl(p.url) catch return errResp(rt, req, .invalid_parameter_value);
    const q = rt.registry.get(name) orelse return errResp(rt, req, .queue_does_not_exist);

    switch (req.protocol) {
        .json => {
            var w = json_proto.Writer.init(arena);
            try w.beginObject();
            try w.writeKey("Tags");
            try w.beginObject();
            var it = q.tags.iterator();
            while (it.next()) |e| {
                try w.writeKey(e.key_ptr.*);
                try w.writeString(e.value_ptr.*);
            }
            try w.endObject();
            try w.endObject();
            return jsonOk(w.finish());
        },
        .query => {
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("ListQueueTagsResponse");
            try x.open("ListQueueTagsResult");
            var it = q.tags.iterator();
            while (it.next()) |e| {
                try x.open("Tag");
                try x.element("Key", e.key_ptr.*);
                try x.element("Value", e.value_ptr.*);
                try x.close("Tag");
            }
            try x.close("ListQueueTagsResult");
            try writeMetadata(&x, req);
            try x.close("ListQueueTagsResponse");
            return xmlOk(x.finish());
        },
    }
}

fn emptyOk(rt: *Runtime, req: *const Request, comptime action: []const u8) !Response {
    _ = rt;
    switch (req.protocol) {
        .json => return jsonOk("{}"),
        .query => {
            const arena = req.arena.allocator();
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open(action ++ "Response");
            try writeMetadata(&x, req);
            try x.close(action ++ "Response");
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
