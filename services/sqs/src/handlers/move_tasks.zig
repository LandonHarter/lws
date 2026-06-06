const std = @import("std");
const dispatch = @import("../wire/dispatch.zig");
const envelope = @import("../wire/envelope.zig");
const handler = @import("../wire/handler.zig");
const json_proto = @import("../wire/json_proto.zig");
const query_proto = @import("../wire/query_proto.zig");
const Runtime = @import("../runtime.zig").Runtime;
const errors = @import("../errors.zig");
const queue = @import("../queue.zig");
const move_task = @import("../store/move_task.zig");

const Request = envelope.Request;
const Response = handler.Response;

pub fn register(gpa: std.mem.Allocator) !void {
    try dispatch.table.register(gpa, "StartMessageMoveTask", startMessageMoveTask);
    try dispatch.table.register(gpa, "CancelMessageMoveTask", cancelMessageMoveTask);
    try dispatch.table.register(gpa, "ListMessageMoveTasks", listMessageMoveTasks);
}

// ---- shared helpers ----

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

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

// ===========================================================================
// StartMessageMoveTask
// ===========================================================================

const StartParams = struct {
    source_arn: []const u8,
    destination_arn: ?[]const u8 = null,
    max_per_sec: ?i64 = null,
};

fn parseStart(req: *const Request) !StartParams {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            const obj = root.object;
            return .{
                .source_arn = jsonString(obj, "SourceArn") orelse return error.MissingSourceArn,
                .destination_arn = jsonString(obj, "DestinationArn"),
                .max_per_sec = jsonInt(obj, "MaxNumberOfMessagesPerSecond"),
            };
        },
        .query => {
            var p: StartParams = .{ .source_arn = (try query_proto.getScalar(req.body, arena, "SourceArn")) orelse return error.MissingSourceArn };
            p.destination_arn = try query_proto.getScalar(req.body, arena, "DestinationArn");
            if (try query_proto.getScalar(req.body, arena, "MaxNumberOfMessagesPerSecond")) |s| {
                p.max_per_sec = std.fmt.parseInt(i64, s, 10) catch return error.InvalidParamValue;
            }
            return p;
        },
    }
}

fn startMessageMoveTask(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const p = parseStart(req) catch |e| return switch (e) {
        error.MissingSourceArn => errMsg(rt, req, .missing_required_parameter, "The request must contain the parameter SourceArn."),
        else => errMsg(rt, req, .invalid_parameter_value, errors.defaultMessage(.invalid_parameter_value)),
    };

    const src = rt.registry.byArn(p.source_arn) orelse
        return errMsg(rt, req, .queue_does_not_exist, errors.defaultMessage(.queue_does_not_exist));

    // The source must be an active dead-letter queue: at least one other queue
    // must name it as its RedrivePolicy target.
    const sources = try rt.registry.dlqSourceNames(arena, p.source_arn);
    if (sources.len == 0) {
        return errMsg(rt, req, .invalid_parameter_value, "Source queue must be configured as a dead-letter queue.");
    }

    // Destination: explicit, or the original source when exactly one exists.
    var dst: *queue.Queue = undefined;
    if (p.destination_arn) |darn| {
        dst = rt.registry.byArn(darn) orelse
            return errMsg(rt, req, .invalid_parameter_value, "The specified destination queue does not exist.");
    } else {
        if (sources.len != 1) {
            return errMsg(rt, req, .invalid_parameter_value, "DestinationArn is required when the dead-letter queue has more than one source.");
        }
        dst = rt.registry.get(sources[0]) orelse
            return errMsg(rt, req, .invalid_parameter_value, "The original source queue no longer exists.");
    }

    var rate: u32 = 0;
    if (p.max_per_sec) |m| {
        if (m < 1 or m > 500) return errMsg(rt, req, .invalid_parameter_value, "MaxNumberOfMessagesPerSecond must be between 1 and 500.");
        rate = @intCast(m);
    }

    const task = rt.move_manager.start(src, dst, rate) catch |e| return switch (e) {
        error.MoveTaskInProgress => errMsg(rt, req, .invalid_parameter_value, "There is already a message move task running for this source queue."),
        else => errMsg(rt, req, .internal_error, errors.defaultMessage(.internal_error)),
    };

    switch (req.protocol) {
        .json => {
            var w = json_proto.Writer.init(arena);
            try w.beginObject();
            try w.writeKey("TaskHandle");
            try w.writeString(&task.id);
            try w.endObject();
            return jsonOk(w.finish());
        },
        .query => {
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("StartMessageMoveTaskResponse");
            try x.open("StartMessageMoveTaskResult");
            try x.element("TaskHandle", &task.id);
            try x.close("StartMessageMoveTaskResult");
            try writeMetadata(&x, req);
            try x.close("StartMessageMoveTaskResponse");
            return xmlOk(x.finish());
        },
    }
}

// ===========================================================================
// CancelMessageMoveTask
// ===========================================================================

fn parseTaskHandle(req: *const Request) !([]const u8) {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            return jsonString(root.object, "TaskHandle") orelse return error.MissingTaskHandle;
        },
        .query => return (try query_proto.getScalar(req.body, arena, "TaskHandle")) orelse return error.MissingTaskHandle,
    }
}

fn cancelMessageMoveTask(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const th = parseTaskHandle(req) catch |e| return switch (e) {
        error.MissingTaskHandle => errMsg(rt, req, .missing_required_parameter, "The request must contain the parameter TaskHandle."),
        else => errMsg(rt, req, .invalid_parameter_value, errors.defaultMessage(.invalid_parameter_value)),
    };
    if (th.len != 36) return errMsg(rt, req, .invalid_parameter_value, "The specified task handle is not valid.");
    var id: [36]u8 = undefined;
    @memcpy(&id, th[0..36]);

    const moved = rt.move_manager.cancel(id) orelse
        return errMsg(rt, req, .invalid_parameter_value, "The specified task handle is not valid.");

    switch (req.protocol) {
        .json => {
            var w = json_proto.Writer.init(arena);
            try w.beginObject();
            try w.writeKey("ApproximateNumberOfMessagesMoved");
            try w.writeInt(@intCast(moved));
            try w.endObject();
            return jsonOk(w.finish());
        },
        .query => {
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("CancelMessageMoveTaskResponse");
            try x.open("CancelMessageMoveTaskResult");
            try x.element("ApproximateNumberOfMessagesMoved", try std.fmt.allocPrint(arena, "{d}", .{moved}));
            try x.close("CancelMessageMoveTaskResult");
            try writeMetadata(&x, req);
            try x.close("CancelMessageMoveTaskResponse");
            return xmlOk(x.finish());
        },
    }
}

// ===========================================================================
// ListMessageMoveTasks
// ===========================================================================

fn parseListSource(req: *const Request) !([]const u8) {
    const arena = req.arena.allocator();
    switch (req.protocol) {
        .json => {
            const root = try json_proto.parsePayload(arena, req.body);
            if (root != .object) return error.InvalidParamValue;
            return jsonString(root.object, "SourceArn") orelse return error.MissingSourceArn;
        },
        .query => return (try query_proto.getScalar(req.body, arena, "SourceArn")) orelse return error.MissingSourceArn,
    }
}

fn listMessageMoveTasks(rt: *Runtime, req: *const Request) anyerror!Response {
    const arena = req.arena.allocator();
    const source_arn = parseListSource(req) catch |e| return switch (e) {
        error.MissingSourceArn => errMsg(rt, req, .missing_required_parameter, "The request must contain the parameter SourceArn."),
        else => errMsg(rt, req, .invalid_parameter_value, errors.defaultMessage(.invalid_parameter_value)),
    };

    const src = rt.registry.byArn(source_arn) orelse
        return errMsg(rt, req, .queue_does_not_exist, errors.defaultMessage(.queue_does_not_exist));

    const tasks = try rt.move_manager.list(arena, src);

    switch (req.protocol) {
        .json => {
            var w = json_proto.Writer.init(arena);
            try w.beginObject();
            try w.writeKey("Results");
            try w.beginArray();
            for (tasks) |t| {
                try w.beginObject();
                try w.writeKey("TaskHandle");
                try w.writeString(&t.id);
                try w.writeKey("Status");
                try w.writeString(t.state.label());
                try w.writeKey("SourceArn");
                try w.writeString(try queueArn(arena, rt, t.src.name));
                try w.writeKey("DestinationArn");
                try w.writeString(try queueArn(arena, rt, t.dst.name));
                if (t.rate_per_sec > 0) {
                    try w.writeKey("MaxNumberOfMessagesPerSecond");
                    try w.writeInt(@intCast(t.rate_per_sec));
                }
                try w.writeKey("ApproximateNumberOfMessagesMoved");
                try w.writeInt(@intCast(t.moved));
                try w.writeKey("ApproximateNumberOfMessagesToMove");
                try w.writeInt(@intCast(messagesToMove(t)));
                try w.writeKey("StartedTimestamp");
                try w.writeInt(t.started_at_ms);
                try w.endObject();
            }
            try w.endArray();
            try w.endObject();
            return jsonOk(w.finish());
        },
        .query => {
            var x = query_proto.XmlWriter.init(arena);
            try x.declaration();
            try x.open("ListMessageMoveTasksResponse");
            try x.open("ListMessageMoveTasksResult");
            for (tasks) |t| {
                try x.open("Results");
                try x.element("TaskHandle", &t.id);
                try x.element("Status", t.state.label());
                try x.element("SourceArn", try queueArn(arena, rt, t.src.name));
                try x.element("DestinationArn", try queueArn(arena, rt, t.dst.name));
                if (t.rate_per_sec > 0) {
                    try x.element("MaxNumberOfMessagesPerSecond", try std.fmt.allocPrint(arena, "{d}", .{t.rate_per_sec}));
                }
                try x.element("ApproximateNumberOfMessagesMoved", try std.fmt.allocPrint(arena, "{d}", .{t.moved}));
                try x.element("ApproximateNumberOfMessagesToMove", try std.fmt.allocPrint(arena, "{d}", .{messagesToMove(t)}));
                try x.element("StartedTimestamp", try std.fmt.allocPrint(arena, "{d}", .{t.started_at_ms}));
                try x.close("Results");
            }
            try x.close("ListMessageMoveTasksResult");
            try writeMetadata(&x, req);
            try x.close("ListMessageMoveTasksResponse");
            return xmlOk(x.finish());
        },
    }
}

fn messagesToMove(t: move_task.TaskInfo) u64 {
    const s = t.src.store orelse return 0;
    const store: *@import("../store/message_store.zig").Store = @ptrCast(@alignCast(s.ctx));
    return store.countVisible();
}

fn queueArn(arena: std.mem.Allocator, rt: *Runtime, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "arn:aws:sqs:{s}:{s}:{s}", .{ rt.region, rt.account, name });
}
