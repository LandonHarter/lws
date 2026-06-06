const std = @import("std");
const server = @import("server");
const id = @import("core").id;
const Runtime = @import("../runtime.zig").Runtime;
const errors = @import("../errors.zig");
const envelope = @import("envelope.zig");
const stats = @import("stats.zig");
const Request = envelope.Request;

pub const Response = struct {
    status: u16 = 200,
    headers: []const std.http.Header = &.{},
    body: []const u8,
    content_type: []const u8 = "application/xml",
};

// Logical operation a request maps to. Handlers slot in per phase; for now the
// dispatcher returns NotImplemented for every operation.
pub const Operation = enum {
    list_buckets,
    create_bucket,
    head_bucket,
    delete_bucket,
    list_objects_v1,
    list_objects_v2,
    list_multipart_uploads,
    delete_objects,
    get_bucket_subres,
    put_bucket_subres,
    delete_bucket_subres,
    put_object,
    get_object,
    head_object,
    delete_object,
    copy_object,
    create_multipart,
    upload_part,
    complete_multipart,
    abort_multipart,
    list_parts,
    get_object_subres,
    put_object_subres,
    delete_object_subres,
    unknown,
};

pub fn operationFor(req: *const Request) Operation {
    return switch (req.scope) {
        .service => switch (req.method) {
            .GET => .list_buckets,
            else => .unknown,
        },
        .bucket => bucketOp(req),
        .object => objectOp(req),
    };
}

fn bucketOp(req: *const Request) Operation {
    return switch (req.subresource) {
        .delete => if (req.method == .POST) .delete_objects else .unknown,
        .uploads, .list_uploads => if (req.method == .GET) .list_multipart_uploads else .unknown,
        .list_v2 => if (req.method == .GET) .list_objects_v2 else .unknown,
        .none, .list_v1 => switch (req.method) {
            .PUT => .create_bucket,
            .HEAD => .head_bucket,
            .DELETE => .delete_bucket,
            .GET => .list_objects_v1,
            else => .unknown,
        },
        else => switch (req.method) {
            .GET => .get_bucket_subres,
            .PUT => .put_bucket_subres,
            .DELETE => .delete_bucket_subres,
            else => .unknown,
        },
    };
}

fn objectOp(req: *const Request) Operation {
    return switch (req.subresource) {
        .uploads => if (req.method == .POST) .create_multipart else .unknown,
        .upload_id => switch (req.method) {
            .PUT => .upload_part,
            .POST => .complete_multipart,
            .DELETE => .abort_multipart,
            .GET => .list_parts,
            else => .unknown,
        },
        .acl, .tagging, .attributes, .retention, .legal_hold => switch (req.method) {
            .GET => .get_object_subres,
            .PUT => .put_object_subres,
            .DELETE => .delete_object_subres,
            else => .unknown,
        },
        .none => switch (req.method) {
            .PUT => if (req.headers.get("x-amz-copy-source") != null) .copy_object else .put_object,
            .GET => .get_object,
            .HEAD => .head_object,
            .DELETE => .delete_object,
            else => .unknown,
        },
        else => .unknown,
    };
}

pub fn handleHttp(ctx: *server.Context) !void {
    const rt: *Runtime = ctx.userData(Runtime);

    if (ctx.method() == .GET and std.mem.eql(u8, ctx.path(), "/health")) {
        return ctx.json(.ok, "{\"status\":\"ok\"}");
    }
    if (ctx.method() == .GET and std.mem.eql(u8, ctx.path(), "/stats")) {
        return stats.handle(ctx, rt);
    }
    if (ctx.method() == .OPTIONS) return permissiveCors(ctx);

    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();

    var req = envelope.parse(&arena, ctx, rt) catch |err| return mapEnvelopeError(ctx, &arena, rt, err);
    const resp = dispatch(rt, &req) catch |err| renderInternalError(&req, err);
    return finishResponse(ctx, &req, resp, arena.allocator());
}

fn dispatch(rt: *Runtime, req: *Request) !Response {
    _ = rt;
    // Routing is fully classified; handlers land in later phases.
    _ = operationFor(req);
    return notImplemented(req);
}

fn notImplemented(req: *const Request) Response {
    const body = errors.render(req.arena.allocator(), .not_implemented, req.bucket, null, &req.request_id) catch "";
    return .{ .status = errors.httpStatus(.not_implemented), .body = body };
}

fn renderInternalError(req: *const Request, err: anyerror) Response {
    _ = err;
    const body = errors.render(req.arena.allocator(), .internal_error, req.bucket, null, &req.request_id) catch "";
    return .{ .status = errors.httpStatus(.internal_error), .body = body };
}

fn finishResponse(ctx: *server.Context, req: *const Request, resp: Response, a: std.mem.Allocator) !void {
    var hdrs: std.ArrayList(std.http.Header) = .empty;
    try hdrs.append(a, .{ .name = "content-type", .value = resp.content_type });
    try hdrs.append(a, .{ .name = "x-amz-request-id", .value = req.request_id[0..] });
    try hdrs.append(a, .{ .name = "x-amz-id-2", .value = "lws" });
    for (resp.headers) |h| try hdrs.append(a, h);

    try ctx.respond(resp.body, .{
        .status = @enumFromInt(resp.status),
        .extra_headers = hdrs.items,
    });
}

fn mapEnvelopeError(ctx: *server.Context, arena: *std.heap.ArenaAllocator, rt: *Runtime, err: anyerror) !void {
    var rid: [36]u8 = undefined;
    id.uuidV4(rt.rng, &rid);
    const code: errors.Code = switch (err) {
        error.MissingAuth => .access_denied,
        error.MethodNotAllowed => .method_not_allowed,
        error.MalformedChunk => .invalid_argument,
        else => .internal_error,
    };
    const body = try errors.render(arena.allocator(), code, null, ctx.path(), rid[0..]);
    try ctx.respond(body, .{
        .status = @enumFromInt(errors.httpStatus(code)),
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/xml" },
            .{ .name = "x-amz-request-id", .value = rid[0..] },
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

fn testReq(method: std.http.Method, scope: envelope.Scope, sub: envelope.Subresource) Request {
    return .{
        .method = method,
        .scope = scope,
        .addressing = .path_style,
        .bucket = "b",
        .key = if (scope == .object) "k" else null,
        .subresource = sub,
        .query = .{},
        .headers = .{},
        .request_id = undefined,
        .authorization = "",
        .content_sha256 = "",
        .is_chunked = false,
        .body = &.{},
        .arena = undefined,
    };
}

test "operationFor route table" {
    try testing.expectEqual(Operation.list_buckets, operationFor(&testReq(.GET, .service, .none)));

    try testing.expectEqual(Operation.create_bucket, operationFor(&testReq(.PUT, .bucket, .none)));
    try testing.expectEqual(Operation.head_bucket, operationFor(&testReq(.HEAD, .bucket, .none)));
    try testing.expectEqual(Operation.delete_bucket, operationFor(&testReq(.DELETE, .bucket, .none)));
    try testing.expectEqual(Operation.list_objects_v1, operationFor(&testReq(.GET, .bucket, .none)));
    try testing.expectEqual(Operation.list_objects_v2, operationFor(&testReq(.GET, .bucket, .list_v2)));
    try testing.expectEqual(Operation.list_multipart_uploads, operationFor(&testReq(.GET, .bucket, .list_uploads)));
    try testing.expectEqual(Operation.delete_objects, operationFor(&testReq(.POST, .bucket, .delete)));
    try testing.expectEqual(Operation.get_bucket_subres, operationFor(&testReq(.GET, .bucket, .location)));
    try testing.expectEqual(Operation.put_bucket_subres, operationFor(&testReq(.PUT, .bucket, .versioning)));
    try testing.expectEqual(Operation.delete_bucket_subres, operationFor(&testReq(.DELETE, .bucket, .tagging)));

    try testing.expectEqual(Operation.put_object, operationFor(&testReq(.PUT, .object, .none)));
    try testing.expectEqual(Operation.get_object, operationFor(&testReq(.GET, .object, .none)));
    try testing.expectEqual(Operation.head_object, operationFor(&testReq(.HEAD, .object, .none)));
    try testing.expectEqual(Operation.delete_object, operationFor(&testReq(.DELETE, .object, .none)));
    try testing.expectEqual(Operation.create_multipart, operationFor(&testReq(.POST, .object, .uploads)));
    try testing.expectEqual(Operation.upload_part, operationFor(&testReq(.PUT, .object, .upload_id)));
    try testing.expectEqual(Operation.complete_multipart, operationFor(&testReq(.POST, .object, .upload_id)));
    try testing.expectEqual(Operation.abort_multipart, operationFor(&testReq(.DELETE, .object, .upload_id)));
    try testing.expectEqual(Operation.list_parts, operationFor(&testReq(.GET, .object, .upload_id)));
    try testing.expectEqual(Operation.get_object_subres, operationFor(&testReq(.GET, .object, .acl)));
}

test "operationFor detects copy via header" {
    var req = testReq(.PUT, .object, .none);
    const hdrs = [_]std.http.Header{.{ .name = "x-amz-copy-source", .value = "/src/k" }};
    req.headers = .{ .items = &hdrs };
    try testing.expectEqual(Operation.copy_object, operationFor(&req));
}
