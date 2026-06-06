const std = @import("std");
const server = @import("server");
const id = @import("core").id;
const query_proto = @import("query_proto.zig");

pub const Protocol = enum { json, query };

pub const Request = struct {
    protocol: Protocol,
    action: []const u8,
    body: []u8,
    request_id: [36]u8,
    authorization: []const u8,
    arena: *std.heap.ArenaAllocator,
};

pub fn parse(arena: *std.heap.ArenaAllocator, ctx: *server.Context, rng: std.Random) !Request {
    if (ctx.method() != .POST) return error.MethodNotAllowed;

    // All header reads must precede readBody: consuming the body advances the
    // HTTP reader past received_head, after which iterateHeaders panics.
    const auth = ctx.header("authorization") orelse "";
    if (auth.len == 0) return error.MissingAuth;

    const ct = ctx.header("content-type") orelse "";
    const is_json = std.mem.startsWith(u8, ct, "application/x-amz-json");
    const is_query = std.mem.startsWith(u8, ct, "application/x-www-form-urlencoded");
    if (!is_json and !is_query) return error.UnsupportedContentType;

    var target: []const u8 = "";
    if (is_json) {
        const tgt = ctx.header("x-amz-target") orelse return error.MissingTarget;
        target = try arena.allocator().dupe(u8, tgt);
    }

    const body = try ctx.readBody();
    const body_dup = try arena.allocator().dupe(u8, body);
    ctx.gpa.free(body);

    var req: Request = .{
        .protocol = undefined,
        .action = "",
        .body = body_dup,
        .request_id = undefined,
        .authorization = try arena.allocator().dupe(u8, auth),
        .arena = arena,
    };
    id.uuidV4(rng, &req.request_id);

    if (is_json) {
        const dot = std.mem.indexOfScalar(u8, target, '.') orelse return error.MalformedTarget;
        req.protocol = .json;
        req.action = target[dot + 1 ..];
    } else {
        req.protocol = .query;
        req.action = try query_proto.extractAction(arena.allocator(), body_dup);
    }
    return req;
}
