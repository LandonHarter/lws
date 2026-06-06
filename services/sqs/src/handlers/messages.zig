const std = @import("std");
const dispatch = @import("../wire/dispatch.zig");
const envelope = @import("../wire/envelope.zig");
const handler = @import("../wire/handler.zig");
const json_proto = @import("../wire/json_proto.zig");
const query_proto = @import("../wire/query_proto.zig");
const Runtime = @import("../runtime.zig").Runtime;
const errors = @import("../errors.zig");
const queue = @import("../queue.zig");
const arn = @import("../arn.zig");
const message = @import("../message.zig");
const message_store = @import("../store/message_store.zig");
const id = @import("core").id;

const Request = envelope.Request;
const Response = handler.Response;

const sender_id = "AIDAIENQZJOLO23YVJ4VO";

pub fn register(gpa: std.mem.Allocator) !void {
    try dispatch.table.register(gpa, "SendMessage", sendMessage);
    try dispatch.table.register(gpa, "ReceiveMessage", receiveMessage);
    try dispatch.table.register(gpa, "DeleteMessage", deleteMessage);
}

// ---- shared helpers ----

fn errResp(rt: *Runtime, req: *const Request, code: errors.Code) Response {
    return handler.renderError(rt, req, code, errors.defaultMessage(code));
}

fn errMsg(rt: *Runtime, req: *const Request, code: errors.Code, msg: []const u8) Response {
    return handler.renderError(rt, req, code, msg);
}

fn jsonOk(body: []const u8) Response {
    return .{ .status = 200, .body = body, .content_type = handler.json_content_type };
}

fn xmlOk(body: []const u8) Response {
    return .{ .status = 200, .body = body, .content_type = handler.xml_content_type };
}

fn writeMetadata(x: *query_proto.XmlWriter, req: *const Request) !void {
    try x.open("ResponseMetadata");
    try x.element("RequestId", req.request_id[0..]);
    try x.close("ResponseMetadata");
}

fn storeOf(q: *queue.Queue) ?*message_store.Store {
    const s = q.store orelse return null;
    return @ptrCast(@alignCast(s.ctx));
}

fn intAttr(q: *queue.Queue, name: []const u8, fallback: i64) i64 {
    const v = q.attributes.get(name) orelse return fallback;
    return switch (v) {
        .integer => |n| n,
        else => fallback,
    };
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn resolveQueue(rt: *Runtime, url: []const u8) !*queue.Queue {
    const name = arn.parseQueueUrl(url) catch return error.BadQueueUrl;
    return rt.registry.get(name) orelse return error.QueueDoesNotExist;
}

// Decodes a base64 binary value into arena; falls back to the raw bytes.
fn decodeBinary(arena: std.mem.Allocator, raw: []const u8) []const u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(raw) catch return raw;
    const out = arena.alloc(u8, n) catch return raw;
    dec.decode(out, raw) catch return raw;
    return out;
}

// ===========================================================================
// SendMessage
// ===========================================================================

const SendParams = struct {
    url: []const u8,
    body: []const u8,
    delay_seconds: ?i64 = null,
    attrs: []message.MessageAttribute = &.{},
    trace_header: ?[]const u8 = null,
    has_group_id: bool = false,
};

fn parseSend(req: *const Request) !SendParams {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            const url = jsonString(obj, "QueueUrl") orelse return error.MissingQueueUrl;
            const body = jsonString(obj, "MessageBody") orelse return error.MissingMessageBody;
            var p: SendParams = .{ .url = url, .body = body };
            if (obj.get("DelaySeconds")) |v| p.delay_seconds = switch (v) {
                .integer => |n| n,
                .string => |s| std.fmt.parseInt(i64, s, 10) catch return error.InvalidParamValue,
                else => return error.InvalidParamValue,
            };
            p.has_group_id = obj.get("MessageGroupId") != null;
            p.attrs = try parseMsgAttrsJson(arena, obj);
            p.trace_header = parseTraceJson(obj);
            return p;
        },
        .query => {
            const url = (try query_proto.getScalar(req.body, arena, "QueueUrl")) orelse return error.MissingQueueUrl;
            const body = (try query_proto.getScalar(req.body, arena, "MessageBody")) orelse return error.MissingMessageBody;
            var p: SendParams = .{ .url = url, .body = body };
            if (try query_proto.getScalar(req.body, arena, "DelaySeconds")) |s| {
                p.delay_seconds = std.fmt.parseInt(i64, s, 10) catch return error.InvalidParamValue;
            }
            p.has_group_id = (try query_proto.getScalar(req.body, arena, "MessageGroupId")) != null;
            p.attrs = try parseMsgAttrsQuery(req.body, arena);
            p.trace_header = try parseTraceQuery(req.body, arena);
            return p;
        },
    }
}

fn parseTraceJson(obj: std.json.ObjectMap) ?[]const u8 {
    const v = obj.get("MessageSystemAttributes") orelse return null;
    if (v != .object) return null;
    const th = v.object.get("AWSTraceHeader") orelse return null;
    if (th != .object) return null;
    return jsonString(th.object, "StringValue");
}

fn parseTraceQuery(body: []const u8, arena: std.mem.Allocator) !?[]const u8 {
    var idx: usize = 1;
    while (true) : (idx += 1) {
        var nb: [128]u8 = undefined;
        const name_key = std.fmt.bufPrint(&nb, "MessageSystemAttribute.{d}.Name", .{idx}) catch break;
        const name = (try query_proto.getScalar(body, arena, name_key)) orelse break;
        if (std.mem.eql(u8, name, "AWSTraceHeader")) {
            var vb: [128]u8 = undefined;
            const val_key = std.fmt.bufPrint(&vb, "MessageSystemAttribute.{d}.Value.StringValue", .{idx}) catch break;
            return try query_proto.getScalar(body, arena, val_key);
        }
    }
    return null;
}

fn parseMsgAttrsJson(arena: std.mem.Allocator, obj: std.json.ObjectMap) ![]message.MessageAttribute {
    const v = obj.get("MessageAttributes") orelse return &.{};
    if (v != .object) return error.InvalidParamValue;
    var list: std.ArrayList(message.MessageAttribute) = .empty;
    var it = v.object.iterator();
    while (it.next()) |e| {
        const spec = e.value_ptr.*;
        if (spec != .object) return error.InvalidParamValue;
        const data_type = jsonString(spec.object, "DataType") orelse return error.InvalidParamValue;
        var a: message.MessageAttribute = .{ .name = e.key_ptr.*, .data_type = data_type };
        if (jsonString(spec.object, "StringValue")) |sv| a.string_value = sv;
        if (jsonString(spec.object, "BinaryValue")) |bv| a.binary_value = decodeBinary(arena, bv);
        try list.append(arena, a);
    }
    return list.items;
}

fn parseMsgAttrsQuery(body: []const u8, arena: std.mem.Allocator) ![]message.MessageAttribute {
    var list: std.ArrayList(message.MessageAttribute) = .empty;
    var idx: usize = 1;
    while (true) : (idx += 1) {
        var nb: [128]u8 = undefined;
        const name_key = std.fmt.bufPrint(&nb, "MessageAttribute.{d}.Name", .{idx}) catch break;
        const name = (try query_proto.getScalar(body, arena, name_key)) orelse break;

        var tb: [160]u8 = undefined;
        const type_key = std.fmt.bufPrint(&tb, "MessageAttribute.{d}.Value.DataType", .{idx}) catch break;
        const data_type = (try query_proto.getScalar(body, arena, type_key)) orelse return error.InvalidParamValue;

        var a: message.MessageAttribute = .{ .name = name, .data_type = data_type };
        var sb: [160]u8 = undefined;
        const sv_key = std.fmt.bufPrint(&sb, "MessageAttribute.{d}.Value.StringValue", .{idx}) catch break;
        if (try query_proto.getScalar(body, arena, sv_key)) |sv| a.string_value = sv;
        var bb: [160]u8 = undefined;
        const bv_key = std.fmt.bufPrint(&bb, "MessageAttribute.{d}.Value.BinaryValue", .{idx}) catch break;
        if (try query_proto.getScalar(body, arena, bv_key)) |bv| a.binary_value = decodeBinary(arena, bv);
        try list.append(arena, a);
    }
    return list.items;
}

const AttrError = error{ BadAttrName, BadAttrType, BadAttrValue };

fn validateAttrs(attrs: []const message.MessageAttribute) AttrError!void {
    for (attrs) |a| {
        try validateAttrName(a.name);
        try validateAttrType(a.data_type);
        const base_binary = std.mem.startsWith(u8, a.data_type, "Binary");
        const base_number = std.mem.startsWith(u8, a.data_type, "Number");
        if (base_binary) {
            if (a.binary_value == null) return AttrError.BadAttrValue;
        } else {
            const sv = a.string_value orelse return AttrError.BadAttrValue;
            if (base_number) {
                _ = std.fmt.parseFloat(f64, sv) catch return AttrError.BadAttrValue;
            }
        }
    }
}

fn validateAttrName(name: []const u8) AttrError!void {
    if (name.len == 0 or name.len > 256) return AttrError.BadAttrName;
    if (name[0] == '.') return AttrError.BadAttrName;
    if (std.mem.startsWith(u8, name, "AWS.") or std.mem.startsWith(u8, name, "Amazon.")) return AttrError.BadAttrName;
    var prev_dot = false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
        if (!ok) return AttrError.BadAttrName;
        if (c == '.') {
            if (prev_dot) return AttrError.BadAttrName;
            prev_dot = true;
        } else prev_dot = false;
    }
}

fn validateAttrType(data_type: []const u8) AttrError!void {
    if (data_type.len == 0 or data_type.len > 256) return AttrError.BadAttrType;
    const base = if (std.mem.indexOfScalar(u8, data_type, '.')) |d| data_type[0..d] else data_type;
    if (!std.mem.eql(u8, base, "String") and !std.mem.eql(u8, base, "Number") and !std.mem.eql(u8, base, "Binary")) {
        return AttrError.BadAttrType;
    }
}

fn sendMessage(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const p = parseSend(req) catch |e| return switch (e) {
        error.MissingQueueUrl, error.MissingMessageBody => errResp(rt, req, .missing_required_parameter),
        else => errResp(rt, req, .invalid_parameter_value),
    };

    const q = resolveQueue(rt, p.url) catch |e| return switch (e) {
        error.QueueDoesNotExist => errResp(rt, req, .queue_does_not_exist),
        else => errResp(rt, req, .invalid_parameter_value),
    };
    const store = storeOf(q) orelse return errResp(rt, req, .internal_error);

    if (p.has_group_id) return errMsg(rt, req, .invalid_parameter_value, "MessageGroupId is supported only for FIFO queues.");
    if (p.body.len == 0) return errResp(rt, req, .missing_required_parameter);

    const max_size = intAttr(q, "MaximumMessageSize", 262144);
    if (@as(i64, @intCast(p.body.len)) > max_size) {
        const msg = try std.fmt.allocPrint(arena, "One or more parameters are invalid. Reason: Message must be shorter than {d} bytes.", .{max_size});
        return errMsg(rt, req, .invalid_parameter_value, msg);
    }

    validateAttrs(p.attrs) catch return errMsg(rt, req, .invalid_parameter_value, "The message attributes are invalid.");

    const delay = p.delay_seconds orelse intAttr(q, "DelaySeconds", 0);
    if (delay < 0 or delay > 900) return errMsg(rt, req, .invalid_parameter_value, "DelaySeconds must be between 0 and 900.");

    var md5_body: [32]u8 = undefined;
    message.computeBodyMd5(&md5_body, p.body);
    var md5_attrs: ?[32]u8 = null;
    if (p.attrs.len > 0) {
        var md: [32]u8 = undefined;
        try message.computeAttrsMd5(arena, &md, p.attrs);
        md5_attrs = md;
    }

    const now = rt.clock.nowMs();
    const msg = try buildStoreMessage(rt, p, md5_body, md5_attrs, now, now + delay * 1000);
    errdefer msg.destroy(rt.gpa);
    try store.send(msg);

    switch (req.protocol) {
        .json => {
            var w = json_proto.Writer.init(arena);
            try w.beginObject();
            try w.writeKey("MessageId");
            try w.writeString(&msg.id);
            try w.writeKey("MD5OfMessageBody");
            try w.writeString(&md5_body);
            if (md5_attrs) |m| {
                try w.writeKey("MD5OfMessageAttributes");
                try w.writeString(&m);
            }
            try w.endObject();
            return jsonOk(w.finish());
        },
        .query => {
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("SendMessageResponse");
            try x.open("SendMessageResult");
            try x.element("MessageId", &msg.id);
            try x.element("MD5OfMessageBody", &md5_body);
            if (md5_attrs) |m| try x.element("MD5OfMessageAttributes", &m);
            try x.close("SendMessageResult");
            try writeMetadata(&x, req);
            try x.close("SendMessageResponse");
            return xmlOk(x.finish());
        },
    }
}

// Allocates the long-lived Message from rt.gpa (the store owns it).
fn buildStoreMessage(rt: *Runtime, p: SendParams, md5_body: [32]u8, md5_attrs: ?[32]u8, sent_at_ms: i64, delay_until_ms: i64) !*message.Message {
    const gpa = rt.gpa;
    const msg = try gpa.create(message.Message);
    errdefer gpa.destroy(msg);

    const attrs = try gpa.alloc(message.MessageAttribute, p.attrs.len);
    var built: usize = 0;
    errdefer {
        for (attrs[0..built]) |a| {
            gpa.free(a.name);
            gpa.free(a.data_type);
            if (a.string_value) |v| gpa.free(v);
            if (a.binary_value) |v| gpa.free(v);
        }
        gpa.free(attrs);
    }
    for (p.attrs, 0..) |a, i| {
        attrs[i] = .{
            .name = try gpa.dupe(u8, a.name),
            .data_type = try gpa.dupe(u8, a.data_type),
            .string_value = if (a.string_value) |v| try gpa.dupe(u8, v) else null,
            .binary_value = if (a.binary_value) |v| try gpa.dupe(u8, v) else null,
        };
        built += 1;
    }

    msg.* = .{
        .id = undefined,
        .seq = 0,
        .body = try gpa.dupe(u8, p.body),
        .md5_of_body = md5_body,
        .md5_of_attrs = md5_attrs,
        .attributes = attrs,
        .sent_at_ms = sent_at_ms,
        .delay_until_ms = delay_until_ms,
        .receive_count = 0,
        .first_received_at_ms = null,
        .trace_header = if (p.trace_header) |t| try gpa.dupe(u8, t) else null,
    };
    id.uuidV4(rt.rng, &msg.id);
    return msg;
}

// ===========================================================================
// ReceiveMessage
// ===========================================================================

const ReceiveParams = struct {
    url: []const u8,
    max: u32 = 1,
    visibility_timeout: ?i64 = null,
    attribute_names: []const []const u8 = &.{},
    message_attribute_names: []const []const u8 = &.{},
};

fn parseReceive(req: *const Request) !ReceiveParams {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            var p: ReceiveParams = .{ .url = jsonString(obj, "QueueUrl") orelse return error.MissingQueueUrl };
            if (obj.get("MaxNumberOfMessages")) |v| p.max = clampMax(switch (v) {
                .integer => |n| n,
                .string => |s| std.fmt.parseInt(i64, s, 10) catch 1,
                else => 1,
            });
            if (obj.get("VisibilityTimeout")) |v| p.visibility_timeout = switch (v) {
                .integer => |n| n,
                .string => |s| std.fmt.parseInt(i64, s, 10) catch return error.InvalidParamValue,
                else => return error.InvalidParamValue,
            };
            p.attribute_names = try jsonStringArray(arena, obj, "AttributeNames");
            p.message_attribute_names = try jsonStringArray(arena, obj, "MessageAttributeNames");
            return p;
        },
        .query => {
            var p: ReceiveParams = .{ .url = (try query_proto.getScalar(req.body, arena, "QueueUrl")) orelse return error.MissingQueueUrl };
            if (try query_proto.getScalar(req.body, arena, "MaxNumberOfMessages")) |s| {
                p.max = clampMax(std.fmt.parseInt(i64, s, 10) catch 1);
            }
            if (try query_proto.getScalar(req.body, arena, "VisibilityTimeout")) |s| {
                p.visibility_timeout = std.fmt.parseInt(i64, s, 10) catch return error.InvalidParamValue;
            }
            p.attribute_names = try query_proto.getIndexedList(req.body, arena, "AttributeName.{i}");
            p.message_attribute_names = try query_proto.getIndexedList(req.body, arena, "MessageAttributeName.{i}");
            return p;
        },
    }
}

fn clampMax(n: i64) u32 {
    if (n < 1) return 1;
    if (n > 10) return 10;
    return @intCast(n);
}

fn jsonStringArray(arena: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const v = obj.get(key) orelse return &.{};
    if (v != .array) return error.InvalidParamValue;
    var out = try arena.alloc([]const u8, v.array.items.len);
    for (v.array.items, 0..) |item, i| {
        if (item != .string) return error.InvalidParamValue;
        out[i] = item.string;
    }
    return out;
}

fn wantsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, "All") or std.mem.eql(u8, n, ".*") or std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn wantsAttrAll(names: []const []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, "All") or std.mem.eql(u8, n, ".*")) return true;
    }
    return false;
}

fn receiveMessage(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const p = parseReceive(req) catch |e| return switch (e) {
        error.MissingQueueUrl => errResp(rt, req, .missing_required_parameter),
        else => errResp(rt, req, .invalid_parameter_value),
    };
    const q = resolveQueue(rt, p.url) catch |e| return switch (e) {
        error.QueueDoesNotExist => errResp(rt, req, .queue_does_not_exist),
        else => errResp(rt, req, .invalid_parameter_value),
    };
    const store = storeOf(q) orelse return errResp(rt, req, .internal_error);

    const vis_sec = p.visibility_timeout orelse intAttr(q, "VisibilityTimeout", 30);
    if (vis_sec < 0 or vis_sec > 43200) return errMsg(rt, req, .invalid_parameter_value, "VisibilityTimeout must be between 0 and 43200.");

    const now = rt.clock.nowMs();
    const received = try store.receive(arena, p.max, vis_sec * 1000, now);

    switch (req.protocol) {
        .json => return jsonOk(try renderReceiveJson(arena, &p, received)),
        .query => return xmlOk(try renderReceiveXml(arena, req, &p, received)),
    }
}

fn renderReceiveJson(arena: std.mem.Allocator, p: *const ReceiveParams, received: []const message_store.ReceivedMessage) ![]const u8 {
    var w = json_proto.Writer.init(arena);
    try w.beginObject();
    if (received.len > 0) {
        try w.writeKey("Messages");
        try w.beginArray();
        for (received) |rm| {
            const m = rm.msg;
            try w.beginObject();
            try w.writeKey("MessageId");
            try w.writeString(&m.id);
            try w.writeKey("ReceiptHandle");
            try w.writeString(rm.receipt_handle);
            try w.writeKey("MD5OfBody");
            try w.writeString(&m.md5_of_body);
            try w.writeKey("Body");
            try w.writeString(m.body);
            if (m.md5_of_attrs) |md| if (anyMsgAttrWanted(p, m)) {
                try w.writeKey("MD5OfMessageAttributes");
                try w.writeString(&md);
            };
            // system attributes
            const sys = try collectSystemAttrs(arena, p.attribute_names, m);
            if (sys.len > 0) {
                try w.writeKey("Attributes");
                try w.beginObject();
                for (sys) |kv| {
                    try w.writeKey(kv.name);
                    try w.writeString(kv.value);
                }
                try w.endObject();
            }
            // message attributes
            if (m.attributes.len > 0) {
                var wrote_any = false;
                for (m.attributes) |a| {
                    if (!wantsName(p.message_attribute_names, a.name)) continue;
                    if (!wrote_any) {
                        try w.writeKey("MessageAttributes");
                        try w.beginObject();
                        wrote_any = true;
                    }
                    try w.writeKey(a.name);
                    try w.beginObject();
                    try w.writeKey("DataType");
                    try w.writeString(a.data_type);
                    if (a.binary_value) |bv| {
                        try w.writeKey("BinaryValue");
                        try w.writeString(try base64Encode(arena, bv));
                    } else if (a.string_value) |sv| {
                        try w.writeKey("StringValue");
                        try w.writeString(sv);
                    }
                    try w.endObject();
                }
                if (wrote_any) try w.endObject();
            }
            try w.endObject();
        }
        try w.endArray();
    }
    try w.endObject();
    return w.finish();
}

fn renderReceiveXml(arena: std.mem.Allocator, req: *const Request, p: *const ReceiveParams, received: []const message_store.ReceivedMessage) ![]const u8 {
    var x = query_proto.XmlWriter.init(arena);
    try x.declaration();
    try x.open("ReceiveMessageResponse");
    try x.open("ReceiveMessageResult");
    for (received) |rm| {
        const m = rm.msg;
        try x.open("Message");
        try x.element("MessageId", &m.id);
        try x.element("ReceiptHandle", rm.receipt_handle);
        try x.element("MD5OfBody", &m.md5_of_body);
        try x.element("Body", m.body);
        if (m.md5_of_attrs) |md| if (anyMsgAttrWanted(p, m)) {
            try x.element("MD5OfMessageAttributes", &md);
        };
        const sys = try collectSystemAttrs(arena, p.attribute_names, m);
        for (sys) |kv| {
            try x.open("Attribute");
            try x.element("Name", kv.name);
            try x.element("Value", kv.value);
            try x.close("Attribute");
        }
        for (m.attributes) |a| {
            if (!wantsName(p.message_attribute_names, a.name)) continue;
            try x.open("MessageAttribute");
            try x.element("Name", a.name);
            try x.open("Value");
            try x.element("DataType", a.data_type);
            if (a.binary_value) |bv| {
                try x.element("BinaryValue", try base64Encode(arena, bv));
            } else if (a.string_value) |sv| {
                try x.element("StringValue", sv);
            }
            try x.close("Value");
            try x.close("MessageAttribute");
        }
        try x.close("Message");
    }
    try x.close("ReceiveMessageResult");
    try writeMetadata(&x, req);
    try x.close("ReceiveMessageResponse");
    return x.finish();
}

fn anyMsgAttrWanted(p: *const ReceiveParams, m: *const message.Message) bool {
    if (m.attributes.len == 0) return false;
    for (m.attributes) |a| {
        if (wantsName(p.message_attribute_names, a.name)) return true;
    }
    return false;
}

fn base64Encode(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, enc.calcSize(bytes.len));
    return enc.encode(out, bytes);
}

const SysAttr = struct { name: []const u8, value: []const u8 };

fn collectSystemAttrs(arena: std.mem.Allocator, names: []const []const u8, m: *const message.Message) ![]SysAttr {
    var out: std.ArrayList(SysAttr) = .empty;
    const all = wantsAttrAll(names);
    if (all or hasName(names, "SenderId")) try out.append(arena, .{ .name = "SenderId", .value = sender_id });
    if (all or hasName(names, "SentTimestamp")) {
        try out.append(arena, .{ .name = "SentTimestamp", .value = try std.fmt.allocPrint(arena, "{d}", .{m.sent_at_ms}) });
    }
    if (all or hasName(names, "ApproximateReceiveCount")) {
        try out.append(arena, .{ .name = "ApproximateReceiveCount", .value = try std.fmt.allocPrint(arena, "{d}", .{m.receive_count}) });
    }
    if (all or hasName(names, "ApproximateFirstReceiveTimestamp")) {
        const fr = m.first_received_at_ms orelse m.sent_at_ms;
        try out.append(arena, .{ .name = "ApproximateFirstReceiveTimestamp", .value = try std.fmt.allocPrint(arena, "{d}", .{fr}) });
    }
    if ((all or hasName(names, "AWSTraceHeader"))) {
        if (m.trace_header) |t| try out.append(arena, .{ .name = "AWSTraceHeader", .value = t });
    }
    return out.items;
}

fn hasName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

// ===========================================================================
// DeleteMessage
// ===========================================================================

const DeleteParams = struct {
    url: []const u8,
    receipt_handle: []const u8,
};

fn parseDelete(req: *const Request) !DeleteParams {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            return .{
                .url = jsonString(obj, "QueueUrl") orelse return error.MissingQueueUrl,
                .receipt_handle = jsonString(obj, "ReceiptHandle") orelse return error.MissingReceiptHandle,
            };
        },
        .query => return .{
            .url = (try query_proto.getScalar(req.body, arena, "QueueUrl")) orelse return error.MissingQueueUrl,
            .receipt_handle = (try query_proto.getScalar(req.body, arena, "ReceiptHandle")) orelse return error.MissingReceiptHandle,
        },
    }
}

fn deleteMessage(rt: *Runtime, req: *const Request) anyerror!Response {
    const p = parseDelete(req) catch |e| return switch (e) {
        error.MissingQueueUrl, error.MissingReceiptHandle => errResp(rt, req, .missing_required_parameter),
        else => errResp(rt, req, .invalid_parameter_value),
    };
    const q = resolveQueue(rt, p.url) catch |e| return switch (e) {
        error.QueueDoesNotExist => errResp(rt, req, .queue_does_not_exist),
        else => errResp(rt, req, .invalid_parameter_value),
    };
    const store = storeOf(q) orelse return errResp(rt, req, .internal_error);

    const h = @import("../receipt.zig").decode(p.receipt_handle) catch return errResp(rt, req, .receipt_handle_invalid);
    if (!std.mem.eql(u8, &h.queue_id, &q.id)) return errResp(rt, req, .receipt_handle_invalid);

    try store.deleteLease(h.msg_seq, h.lease_nonce);

    switch (req.protocol) {
        .json => return jsonOk("{}"),
        .query => {
            const arena = req.arena.allocator();
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("DeleteMessageResponse");
            try writeMetadata(&x, req);
            try x.close("DeleteMessageResponse");
            return xmlOk(x.finish());
        },
    }
}
