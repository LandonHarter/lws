const std = @import("std");
const server = @import("server");
const build_options = @import("build_options");
const id = @import("core").id;
const Runtime = @import("../runtime.zig").Runtime;
const stats = @import("stats.zig");
const envelope = @import("envelope.zig");
const handlers = @import("handlers.zig");
const items = @import("item_handlers.zig");
const errors = @import("../errors.zig");

const Request = envelope.Request;
const Response = envelope.Response;

pub fn handleHttp(ctx: *server.Context) !void {
    const rt: *Runtime = ctx.userData(Runtime);

    if (ctx.method() == .GET and std.mem.eql(u8, ctx.path(), "/health")) {
        return ctx.json(.ok, "{\"status\":\"ok\",\"version\":\"" ++ build_options.version ++ "\"}");
    }
    if (ctx.method() == .GET and std.mem.eql(u8, ctx.path(), "/stats")) {
        return stats.handle(ctx, rt);
    }
    if (ctx.method() == .OPTIONS) return permissiveCors(ctx);

    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();

    var req = envelope.parse(ctx, rt, &arena) catch |err| return mapParseError(ctx, &arena, rt, err);
    const resp = dispatch(rt, &req) catch |err| renderInternalError(&req, err);
    return envelope.finishResponse(ctx, &req, resp, arena.allocator());
}

fn dispatch(rt: *Runtime, req: *Request) !Response {
    return switch (req.target) {
        .create_table => handlers.createTable(rt, req),
        .delete_table => handlers.deleteTable(rt, req),
        .describe_table => handlers.describeTable(rt, req),
        .list_tables => handlers.listTables(rt, req),
        .update_table => handlers.updateTable(rt, req),
        .update_time_to_live => handlers.updateTimeToLive(rt, req),
        .describe_time_to_live => handlers.describeTimeToLive(rt, req),
        .list_tags_of_resource => handlers.listTagsOfResource(rt, req),
        .tag_resource => handlers.tagResource(rt, req),
        .untag_resource => handlers.untagResource(rt, req),
        .put_item => items.putItem(rt, req),
        .get_item => items.getItem(rt, req),
        .update_item => items.updateItem(rt, req),
        .delete_item => items.deleteItem(rt, req),
        .batch_get_item => items.batchGetItem(rt, req),
        .batch_write_item => items.batchWriteItem(rt, req),
        .query => items.query(rt, req),
        .scan => items.scan(rt, req),
        .transact_get_items => items.transactGetItems(rt, req),
        .transact_write_items => items.transactWriteItems(rt, req),
        .unknown => unknownOperation(req),
    };
}

fn unknownOperation(req: *const Request) Response {
    const body = errors.render(req.arena.allocator(), .unknown_operation, errors.defaultMessage(.unknown_operation)) catch "";
    return .{ .status = errors.httpStatus(.unknown_operation), .body = body };
}

fn renderInternalError(req: *const Request, err: anyerror) Response {
    _ = &err;
    const body = errors.render(req.arena.allocator(), .internal_server_error, errors.defaultMessage(.internal_server_error)) catch "";
    return .{ .status = errors.httpStatus(.internal_server_error), .body = body };
}

fn parseErrorCode(err: anyerror) errors.Code {
    return switch (err) {
        error.MalformedBody => .serialization_exception,
        error.MethodNotAllowed, error.MissingTarget => .unknown_operation,
        else => .internal_server_error,
    };
}

fn mapParseError(ctx: *server.Context, arena: *std.heap.ArenaAllocator, rt: *Runtime, err: anyerror) !void {
    var rid: [36]u8 = undefined;
    id.uuidV4(rt.rng, &rid);
    const code = parseErrorCode(err);
    const body = errors.render(arena.allocator(), code, errors.defaultMessage(code)) catch "";
    try ctx.respond(body, .{
        .status = @enumFromInt(errors.httpStatus(code)),
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-amz-json-1.0" },
            .{ .name = "x-amzn-requestid", .value = rid[0..] },
            .{ .name = "x-amz-id-2", .value = "lws" },
        },
    });
}

fn permissiveCors(ctx: *server.Context) !void {
    try ctx.respond("", .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "access-control-allow-origin", .value = "*" },
            .{ .name = "access-control-allow-methods", .value = "GET, PUT, POST, DELETE, HEAD" },
            .{ .name = "access-control-allow-headers", .value = "*" },
            .{ .name = "x-amz-id-2", .value = "lws" },
        },
    });
}

const testing = std.testing;

fn buildRequest(arena: *std.heap.ArenaAllocator, target: @import("operation.zig").Operation, json: []const u8) !Request {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    return .{ .target = target, .body = parsed, .request_id = [_]u8{'0'} ** 36, .arena = arena };
}

test "dispatch returns unknown_operation for unknown target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var rt: Runtime = undefined;
    var req = try buildRequest(&arena, .unknown, "{}");
    const resp = try dispatch(&rt, &req);
    try testing.expectEqual(@as(u16, 400), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "UnknownOperationException") != null);
}

test "parseErrorCode maps malformed body to serialization" {
    try testing.expectEqual(errors.Code.serialization_exception, parseErrorCode(error.MalformedBody));
    try testing.expectEqual(errors.Code.unknown_operation, parseErrorCode(error.MissingTarget));
    try testing.expectEqual(errors.Code.unknown_operation, parseErrorCode(error.MethodNotAllowed));
}
