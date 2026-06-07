const std = @import("std");
const server = @import("server");
const id = @import("core").id;
const json_proto = @import("json_proto.zig");
const operation = @import("operation.zig");
const Operation = operation.Operation;
const Runtime = @import("../runtime.zig").Runtime;

pub const Request = struct {
    target: Operation,
    body: std.json.Value,
    request_id: [36]u8,
    arena: *std.heap.ArenaAllocator,
};

pub const Response = struct {
    status: u16 = 200,
    body: []const u8,
};

pub const ParseError = error{
    MethodNotAllowed,
    MissingTarget,
    MalformedBody,
};

// Validates POST + X-Amz-Target, parses the JSON body. Header reads must precede
// readBody: consuming the body advances the HTTP reader past received_head.
pub fn parse(ctx: *server.Context, rt: *Runtime, arena: *std.heap.ArenaAllocator) !Request {
    if (ctx.method() != .POST) return error.MethodNotAllowed;

    const tgt = ctx.header("x-amz-target") orelse return error.MissingTarget;
    const target_dup = try arena.allocator().dupe(u8, tgt);

    const body = try ctx.readBody();
    const body_dup = try arena.allocator().dupe(u8, body);
    ctx.gpa.free(body);

    const parsed = json_proto.parsePayload(arena.allocator(), body_dup) catch return error.MalformedBody;

    var req: Request = .{
        .target = operation.fromTarget(target_dup),
        .body = parsed,
        .request_id = undefined,
        .arena = arena,
    };
    id.uuidV4(rt.rng, &req.request_id);
    return req;
}

// Writes the success/error body with DynamoDB's response headers: content type,
// request id, and a CRC32 of the body (SDKs verify it when present).
pub fn finishResponse(ctx: *server.Context, req: *const Request, resp: Response, a: std.mem.Allocator) !void {
    const crc = std.hash.crc.Crc32.hash(resp.body);
    const crc_str = try std.fmt.allocPrint(a, "{d}", .{crc});
    try ctx.respond(resp.body, .{
        .status = @enumFromInt(resp.status),
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-amz-json-1.0" },
            .{ .name = "x-amzn-requestid", .value = req.request_id[0..] },
            .{ .name = "x-amz-crc32", .value = crc_str },
            .{ .name = "x-amz-id-2", .value = "lws" },
        },
    });
}
