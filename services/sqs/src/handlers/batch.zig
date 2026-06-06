const std = @import("std");
const dispatch = @import("../wire/dispatch.zig");
const envelope = @import("../wire/envelope.zig");
const handler = @import("../wire/handler.zig");
const json_proto = @import("../wire/json_proto.zig");
const query_proto = @import("../wire/query_proto.zig");
const Runtime = @import("../runtime.zig").Runtime;
const errors = @import("../errors.zig");
const queue = @import("../queue.zig");
const messages = @import("messages.zig");
const batch_util = @import("batch_util.zig");

const Request = envelope.Request;
const Response = handler.Response;
const SendParams = messages.SendParams;
const BatchResultEntry = batch_util.BatchResultEntry;

const send_prefix = "SendMessageBatchRequestEntry";
const delete_prefix = "DeleteMessageBatchRequestEntry";
const cv_prefix = "ChangeMessageVisibilityBatchRequestEntry";

pub fn register(gpa: std.mem.Allocator) !void {
    try dispatch.table.register(gpa, "SendMessageBatch", sendMessageBatch);
    try dispatch.table.register(gpa, "DeleteMessageBatch", deleteMessageBatch);
    try dispatch.table.register(gpa, "ChangeMessageVisibility", changeMessageVisibility);
    try dispatch.table.register(gpa, "ChangeMessageVisibilityBatch", changeMessageVisibilityBatch);
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

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) !?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch return error.InvalidParamValue,
        else => error.InvalidParamValue,
    };
}

fn collectIds(arena: std.mem.Allocator, comptime T: type, entries: []const T) ![]const []const u8 {
    const ids = try arena.alloc([]const u8, entries.len);
    for (entries, 0..) |e, i| ids[i] = e.id;
    return ids;
}

fn renderBatch(req: *const Request, action: batch_util.BatchAction, results: []const BatchResultEntry) !Response {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => return jsonOk(try batch_util.writeJson(arena, action, results)),
        .query => return xmlOk(try batch_util.writeXml(arena, action, results, &req.request_id)),
    }
}

fn failureOf(id: []const u8, se: messages.SingleError) BatchResultEntry {
    return .{ .failure = .{
        .id = id,
        .code = errors.queryCode(se.code),
        .message = se.message,
        .sender_fault = se.code != .internal_error,
    } };
}

// ===========================================================================
// SendMessageBatch
// ===========================================================================

const SendEntry = struct { id: []const u8, params: SendParams };

fn parseSendBatch(req: *const Request) !struct { url: []const u8, entries: []SendEntry } {
    const arena = req.arena.allocator();
    var list: std.ArrayList(SendEntry) = .empty;
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            const url = jsonString(obj, "QueueUrl") orelse return error.MissingQueueUrl;
            if (obj.get("Entries")) |ev| {
                if (ev == .array) {
                    for (ev.array.items) |item| {
                        if (item != .object) return error.InvalidParamValue;
                        const eo = item.object;
                        var p: SendParams = .{ .url = url, .body = jsonString(eo, "MessageBody") orelse "" };
                        p.delay_seconds = try jsonInt(eo, "DelaySeconds");
                        p.group_id = jsonString(eo, "MessageGroupId");
                        p.dedup_id = jsonString(eo, "MessageDeduplicationId");
                        p.attrs = try messages.parseMsgAttrsJson(arena, eo);
                        p.trace_header = messages.parseTraceJson(eo);
                        try list.append(arena, .{ .id = jsonString(eo, "Id") orelse "", .params = p });
                    }
                }
            }
            return .{ .url = url, .entries = list.items };
        },
        .query => {
            const url = (try query_proto.getScalar(req.body, arena, "QueueUrl")) orelse return error.MissingQueueUrl;
            var n: usize = 1;
            while (true) : (n += 1) {
                const idv = (try entryScalar(req.body, arena, send_prefix, n, "Id")) orelse break;
                var p: SendParams = .{ .url = url, .body = (try entryScalar(req.body, arena, send_prefix, n, "MessageBody")) orelse "" };
                if (try entryScalar(req.body, arena, send_prefix, n, "DelaySeconds")) |s| {
                    p.delay_seconds = std.fmt.parseInt(i64, s, 10) catch return error.InvalidParamValue;
                }
                p.group_id = try entryScalar(req.body, arena, send_prefix, n, "MessageGroupId");
                p.dedup_id = try entryScalar(req.body, arena, send_prefix, n, "MessageDeduplicationId");
                const attr_prefix = try std.fmt.allocPrint(arena, "{s}.{d}.MessageAttribute", .{ send_prefix, n });
                p.attrs = try messages.parseMsgAttrsQueryPrefixed(req.body, arena, attr_prefix);
                const sys_prefix = try std.fmt.allocPrint(arena, "{s}.{d}.MessageSystemAttribute", .{ send_prefix, n });
                p.trace_header = try messages.parseTraceQueryPrefixed(req.body, arena, sys_prefix);
                try list.append(arena, .{ .id = idv, .params = p });
            }
            return .{ .url = url, .entries = list.items };
        },
    }
}

fn entryScalar(body: []const u8, arena: std.mem.Allocator, prefix: []const u8, n: usize, field: []const u8) !?[]const u8 {
    var kb: [128]u8 = undefined;
    const key = batch_util.entryKey(&kb, prefix, n, field) catch return null;
    return query_proto.getScalar(body, arena, key);
}

fn sendMessageBatch(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const parsed = parseSendBatch(req) catch |e| return switch (e) {
        error.MissingQueueUrl => errResp(rt, req, .missing_required_parameter),
        else => errResp(rt, req, .invalid_parameter_value),
    };
    const q = messages.resolveQueue(rt, parsed.url) catch |e| return switch (e) {
        error.QueueDoesNotExist => errResp(rt, req, .queue_does_not_exist),
        else => errResp(rt, req, .invalid_parameter_value),
    };

    const ids = try collectIds(arena, SendEntry, parsed.entries);
    batch_util.validateIds(ids) catch |e| return errResp(rt, req, batch_util.envelopeCode(e));

    var total: usize = 0;
    for (parsed.entries) |e| total += e.params.body.len;
    if (total > 262144) return errResp(rt, req, .batch_request_too_long);

    const results = try arena.alloc(BatchResultEntry, parsed.entries.len);
    for (parsed.entries, 0..) |e, i| {
        const attempt = messages.singleSend(rt, arena, q, e.params) catch |err| return switch (err) {
            error.NoStore => errResp(rt, req, .internal_error),
            else => err,
        };
        results[i] = switch (attempt) {
            .ok => |o| .{ .success = .{
                .id = e.id,
                .message_id = o.id,
                .md5_of_body = o.md5_of_body,
                .md5_of_attrs = o.md5_of_attrs,
                .sequence_number = o.sequence_number,
            } },
            .err => |se| failureOf(e.id, se),
        };
    }

    return renderBatch(req, .send, results);
}

// ===========================================================================
// DeleteMessageBatch
// ===========================================================================

const DeleteEntry = struct { id: []const u8, receipt_handle: []const u8 };

fn parseDeleteBatch(req: *const Request) !struct { url: []const u8, entries: []DeleteEntry } {
    const arena = req.arena.allocator();
    var list: std.ArrayList(DeleteEntry) = .empty;
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            const url = jsonString(obj, "QueueUrl") orelse return error.MissingQueueUrl;
            if (obj.get("Entries")) |ev| {
                if (ev == .array) {
                    for (ev.array.items) |item| {
                        if (item != .object) return error.InvalidParamValue;
                        const eo = item.object;
                        try list.append(arena, .{
                            .id = jsonString(eo, "Id") orelse "",
                            .receipt_handle = jsonString(eo, "ReceiptHandle") orelse "",
                        });
                    }
                }
            }
            return .{ .url = url, .entries = list.items };
        },
        .query => {
            const url = (try query_proto.getScalar(req.body, arena, "QueueUrl")) orelse return error.MissingQueueUrl;
            var n: usize = 1;
            while (true) : (n += 1) {
                const idv = (try entryScalar(req.body, arena, delete_prefix, n, "Id")) orelse break;
                const rh = (try entryScalar(req.body, arena, delete_prefix, n, "ReceiptHandle")) orelse "";
                try list.append(arena, .{ .id = idv, .receipt_handle = rh });
            }
            return .{ .url = url, .entries = list.items };
        },
    }
}

fn deleteMessageBatch(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const parsed = parseDeleteBatch(req) catch |e| return switch (e) {
        error.MissingQueueUrl => errResp(rt, req, .missing_required_parameter),
        else => errResp(rt, req, .invalid_parameter_value),
    };
    const q = messages.resolveQueue(rt, parsed.url) catch |e| return switch (e) {
        error.QueueDoesNotExist => errResp(rt, req, .queue_does_not_exist),
        else => errResp(rt, req, .invalid_parameter_value),
    };

    const ids = try collectIds(arena, DeleteEntry, parsed.entries);
    batch_util.validateIds(ids) catch |e| return errResp(rt, req, batch_util.envelopeCode(e));

    const results = try arena.alloc(BatchResultEntry, parsed.entries.len);
    for (parsed.entries, 0..) |e, i| {
        const maybe = messages.singleDelete(q, e.receipt_handle) catch |err| return switch (err) {
            error.NoStore => errResp(rt, req, .internal_error),
            else => err,
        };
        results[i] = if (maybe) |se| failureOf(e.id, se) else .{ .success = .{ .id = e.id } };
    }

    return renderBatch(req, .delete, results);
}

// ===========================================================================
// ChangeMessageVisibility (single)
// ===========================================================================

const CvParams = struct { url: []const u8, receipt_handle: []const u8, visibility_timeout: ?i64 };

fn parseChangeVisibility(req: *const Request) !CvParams {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            return .{
                .url = jsonString(obj, "QueueUrl") orelse return error.MissingQueueUrl,
                .receipt_handle = jsonString(obj, "ReceiptHandle") orelse return error.MissingReceiptHandle,
                .visibility_timeout = try jsonInt(obj, "VisibilityTimeout"),
            };
        },
        .query => {
            const url = (try query_proto.getScalar(req.body, arena, "QueueUrl")) orelse return error.MissingQueueUrl;
            const rh = (try query_proto.getScalar(req.body, arena, "ReceiptHandle")) orelse return error.MissingReceiptHandle;
            var vt: ?i64 = null;
            if (try query_proto.getScalar(req.body, arena, "VisibilityTimeout")) |s| {
                vt = std.fmt.parseInt(i64, s, 10) catch return error.InvalidParamValue;
            }
            return .{ .url = url, .receipt_handle = rh, .visibility_timeout = vt };
        },
    }
}

fn changeMessageVisibility(rt: *Runtime, req: *const Request) anyerror!Response {
    const p = parseChangeVisibility(req) catch |e| return switch (e) {
        error.MissingQueueUrl, error.MissingReceiptHandle => errResp(rt, req, .missing_required_parameter),
        else => errResp(rt, req, .invalid_parameter_value),
    };
    const q = messages.resolveQueue(rt, p.url) catch |e| return switch (e) {
        error.QueueDoesNotExist => errResp(rt, req, .queue_does_not_exist),
        else => errResp(rt, req, .invalid_parameter_value),
    };
    const vt = p.visibility_timeout orelse return errResp(rt, req, .missing_required_parameter);

    const maybe = messages.singleChangeVisibility(rt, q, p.receipt_handle, vt) catch |e| return switch (e) {
        error.NoStore => errResp(rt, req, .internal_error),
        else => e,
    };
    if (maybe) |se| return errMsg(rt, req, se.code, se.message);

    switch (req.protocol) {
        .json => return jsonOk("{}"),
        .query => {
            const arena = req.arena.allocator();
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("ChangeMessageVisibilityResponse");
            try x.open("ResponseMetadata");
            try x.element("RequestId", &req.request_id);
            try x.close("ResponseMetadata");
            try x.close("ChangeMessageVisibilityResponse");
            return xmlOk(x.finish());
        },
    }
}

// ===========================================================================
// ChangeMessageVisibilityBatch
// ===========================================================================

const CvEntry = struct { id: []const u8, receipt_handle: []const u8, visibility_timeout: ?i64 };

fn parseChangeVisibilityBatch(req: *const Request) !struct { url: []const u8, entries: []CvEntry } {
    const arena = req.arena.allocator();
    var list: std.ArrayList(CvEntry) = .empty;
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            const url = jsonString(obj, "QueueUrl") orelse return error.MissingQueueUrl;
            if (obj.get("Entries")) |ev| {
                if (ev == .array) {
                    for (ev.array.items) |item| {
                        if (item != .object) return error.InvalidParamValue;
                        const eo = item.object;
                        try list.append(arena, .{
                            .id = jsonString(eo, "Id") orelse "",
                            .receipt_handle = jsonString(eo, "ReceiptHandle") orelse "",
                            .visibility_timeout = try jsonInt(eo, "VisibilityTimeout"),
                        });
                    }
                }
            }
            return .{ .url = url, .entries = list.items };
        },
        .query => {
            const url = (try query_proto.getScalar(req.body, arena, "QueueUrl")) orelse return error.MissingQueueUrl;
            var n: usize = 1;
            while (true) : (n += 1) {
                const idv = (try entryScalar(req.body, arena, cv_prefix, n, "Id")) orelse break;
                const rh = (try entryScalar(req.body, arena, cv_prefix, n, "ReceiptHandle")) orelse "";
                var vt: ?i64 = null;
                if (try entryScalar(req.body, arena, cv_prefix, n, "VisibilityTimeout")) |s| {
                    vt = std.fmt.parseInt(i64, s, 10) catch return error.InvalidParamValue;
                }
                try list.append(arena, .{ .id = idv, .receipt_handle = rh, .visibility_timeout = vt });
            }
            return .{ .url = url, .entries = list.items };
        },
    }
}

fn changeMessageVisibilityBatch(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const parsed = parseChangeVisibilityBatch(req) catch |e| return switch (e) {
        error.MissingQueueUrl => errResp(rt, req, .missing_required_parameter),
        else => errResp(rt, req, .invalid_parameter_value),
    };
    const q = messages.resolveQueue(rt, parsed.url) catch |e| return switch (e) {
        error.QueueDoesNotExist => errResp(rt, req, .queue_does_not_exist),
        else => errResp(rt, req, .invalid_parameter_value),
    };

    const ids = try collectIds(arena, CvEntry, parsed.entries);
    batch_util.validateIds(ids) catch |e| return errResp(rt, req, batch_util.envelopeCode(e));

    const results = try arena.alloc(BatchResultEntry, parsed.entries.len);
    for (parsed.entries, 0..) |e, i| {
        const vt = e.visibility_timeout orelse {
            results[i] = failureOf(e.id, .{ .code = .missing_required_parameter, .message = "The request must contain the parameter VisibilityTimeout." });
            continue;
        };
        const maybe = messages.singleChangeVisibility(rt, q, e.receipt_handle, vt) catch |err| return switch (err) {
            error.NoStore => errResp(rt, req, .internal_error),
            else => err,
        };
        results[i] = if (maybe) |se| failureOf(e.id, se) else .{ .success = .{ .id = e.id } };
    }

    return renderBatch(req, .change_visibility, results);
}
