const std = @import("std");
const dispatch = @import("../wire/dispatch.zig");
const envelope = @import("../wire/envelope.zig");
const handler = @import("../wire/handler.zig");
const json_proto = @import("../wire/json_proto.zig");
const query_proto = @import("../wire/query_proto.zig");
const Runtime = @import("../runtime.zig").Runtime;
const errors = @import("../errors.zig");
const arn = @import("../arn.zig");
const policy = @import("../policy.zig");

const Request = envelope.Request;
const Response = handler.Response;

const max_label_len = 80;

const known_actions = [_][]const u8{
    "*",
    "SendMessage",
    "ReceiveMessage",
    "DeleteMessage",
    "ChangeMessageVisibility",
    "GetQueueAttributes",
    "GetQueueUrl",
    "ListDeadLetterSourceQueues",
    "PurgeQueue",
};

pub fn register(gpa: std.mem.Allocator) !void {
    try dispatch.table.register(gpa, "AddPermission", addPermission);
    try dispatch.table.register(gpa, "RemovePermission", removePermission);
}

fn errResp(rt: *Runtime, req: *const Request, code: errors.Code) Response {
    return handler.renderError(rt, req, code, errors.defaultMessage(code));
}

fn mapParamErr(rt: *Runtime, req: *const Request, err: anyerror) Response {
    return switch (err) {
        error.MissingQueueUrl, error.MissingLabel => errResp(rt, req, .missing_required_parameter),
        else => errResp(rt, req, .invalid_parameter_value),
    };
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

const AddParams = struct {
    url: []const u8,
    label: []const u8,
    account_ids: []const []const u8,
    actions: []const []const u8,
};

fn parseAdd(req: *const Request) !AddParams {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            return .{
                .url = jsonString(obj, "QueueUrl") orelse return error.MissingQueueUrl,
                .label = jsonString(obj, "Label") orelse return error.MissingLabel,
                .account_ids = try jsonStringArray(arena, obj, "AWSAccountIds"),
                .actions = try jsonStringArray(arena, obj, "Actions"),
            };
        },
        .query => {
            return .{
                .url = (try query_proto.getScalar(req.body, arena, "QueueUrl")) orelse return error.MissingQueueUrl,
                .label = (try query_proto.getScalar(req.body, arena, "Label")) orelse return error.MissingLabel,
                .account_ids = try query_proto.getIndexedList(req.body, arena, "AWSAccountId.{i}"),
                .actions = try query_proto.getIndexedList(req.body, arena, "ActionName.{i}"),
            };
        },
    }
}

const RemoveParams = struct { url: []const u8, label: []const u8 };

fn parseRemove(req: *const Request) !RemoveParams {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            return .{
                .url = jsonString(obj, "QueueUrl") orelse return error.MissingQueueUrl,
                .label = jsonString(obj, "Label") orelse return error.MissingLabel,
            };
        },
        .query => {
            return .{
                .url = (try query_proto.getScalar(req.body, arena, "QueueUrl")) orelse return error.MissingQueueUrl,
                .label = (try query_proto.getScalar(req.body, arena, "Label")) orelse return error.MissingLabel,
            };
        },
    }
}

// ---- validation ----

fn validLabel(label: []const u8) bool {
    if (label.len < 1 or label.len > max_label_len) return false;
    for (label) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

fn knownAction(name: []const u8) bool {
    for (known_actions) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

// ---- handlers ----

fn addPermission(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const p = parseAdd(req) catch |e| return mapParamErr(rt, req, e);
    const name = arn.parseQueueUrl(p.url) catch return errResp(rt, req, .invalid_parameter_value);
    if (rt.registry.get(name) == null) return errResp(rt, req, .queue_does_not_exist);

    if (!validLabel(p.label)) {
        const msg = try std.fmt.allocPrint(arena, "Value {s} for parameter Label is invalid. Reason: Label can only include alphanumeric characters, hyphens, or underscores. 1 to 80 in length.", .{p.label});
        return handler.renderError(rt, req, .invalid_parameter_value, msg);
    }
    if (p.account_ids.len == 0 or p.actions.len == 0) return errResp(rt, req, .invalid_parameter_value);
    for (p.actions) |action| {
        if (!knownAction(action)) {
            const msg = try std.fmt.allocPrint(arena, "Value SQS:{s} for parameter ActionName is invalid. Reason: Please refer to the appropriate WSDL for a list of valid actions.", .{action});
            return handler.renderError(rt, req, .invalid_parameter_value, msg);
        }
    }

    const principals = try arena.alloc([]const u8, p.account_ids.len);
    for (p.account_ids, 0..) |acct, i| {
        if (acct.len == 0) return errResp(rt, req, .invalid_parameter_value);
        principals[i] = try std.fmt.allocPrint(arena, "arn:aws:iam::{s}:root", .{acct});
    }
    const action_arns = try arena.alloc([]const u8, p.actions.len);
    for (p.actions, 0..) |action, i| {
        action_arns[i] = try std.fmt.allocPrint(arena, "SQS:{s}", .{action});
    }

    const resource = try queueArn(arena, rt, name);
    const policy_id = try std.fmt.allocPrint(arena, "{s}/SQSDefaultPolicy", .{resource});

    rt.registry.addPermission(name, .{
        .sid = p.label,
        .principal_arns = principals,
        .action_arns = action_arns,
        .resource = resource,
    }, policy_id) catch |e| switch (e) {
        error.DuplicateLabel => {
            const msg = try std.fmt.allocPrint(arena, "Value {s} for parameter Label is invalid. Reason: Already exists.", .{p.label});
            return handler.renderError(rt, req, .invalid_parameter_value, msg);
        },
        error.QueueDoesNotExist => return errResp(rt, req, .queue_does_not_exist),
        else => return errResp(rt, req, .internal_error),
    };

    return emptyOk(req, "AddPermission");
}

fn removePermission(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const p = parseRemove(req) catch |e| return mapParamErr(rt, req, e);
    const name = arn.parseQueueUrl(p.url) catch return errResp(rt, req, .invalid_parameter_value);
    if (rt.registry.get(name) == null) return errResp(rt, req, .queue_does_not_exist);

    rt.registry.removePermission(name, p.label) catch |e| switch (e) {
        error.StatementNotFound => {
            const msg = try std.fmt.allocPrint(arena, "Value {s} for parameter Label is invalid. Reason: Statement does not exist.", .{p.label});
            return handler.renderError(rt, req, .invalid_parameter_value, msg);
        },
        error.QueueDoesNotExist => return errResp(rt, req, .queue_does_not_exist),
        else => return errResp(rt, req, .internal_error),
    };

    return emptyOk(req, "RemovePermission");
}

fn emptyOk(req: *const Request, comptime action: []const u8) !Response {
    switch (req.protocol) {
        .json => return jsonOk("{}"),
        .query => {
            const arena = req.arena.allocator();
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open(action ++ "Response");
            try x.open("ResponseMetadata");
            try x.element("RequestId", req.request_id[0..]);
            try x.close("ResponseMetadata");
            try x.close(action ++ "Response");
            return xmlOk(x.finish());
        },
    }
}

fn jsonOk(body: []const u8) Response {
    return .{ .status = 200, .body = body, .content_type = handler.json_content_type };
}

fn xmlOk(body: []const u8) Response {
    return .{ .status = 200, .body = body, .content_type = handler.xml_content_type };
}
