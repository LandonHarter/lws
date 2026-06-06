const std = @import("std");
const server = @import("server");
const Runtime = @import("../runtime.zig").Runtime;
const envelope = @import("envelope.zig");
const handler_mod = @import("handler.zig");
const Handler = handler_mod.Handler;
const Response = handler_mod.Response;
const stats = @import("stats.zig");

pub const Table = struct {
    actions: std.StringArrayHashMapUnmanaged(Handler) = .empty,

    pub fn register(self: *Table, gpa: std.mem.Allocator, name: []const u8, h: Handler) !void {
        try self.actions.put(gpa, name, h);
    }

    pub fn get(self: *const Table, name: []const u8) ?Handler {
        return self.actions.get(name);
    }
};

pub var table: Table = .{};

pub fn handleHttp(ctx: *server.Context) !void {
    const rt: *Runtime = ctx.userData(Runtime);

    if (ctx.method() == .GET and std.mem.eql(u8, ctx.path(), "/health")) {
        return ctx.json(.ok, "{\"status\":\"ok\"}");
    }

    if (ctx.method() == .GET and std.mem.eql(u8, ctx.path(), "/stats")) {
        return stats.handle(ctx, rt);
    }

    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();

    const req_or_err = envelope.parse(&arena, ctx, rt.rng);
    if (req_or_err) |req| {
        const resp = if (table.get(req.action)) |h|
            handler_mod.renderResult(rt, &req, h(rt, &req))
        else
            handler_mod.renderError(rt, &req, .unrecognized_action, "The action or operation requested is invalid.");
        return finishResponse(ctx, &req, resp);
    } else |err| return mapEnvelopeError(ctx, err);
}

fn finishResponse(ctx: *server.Context, req: *const envelope.Request, resp: Response) !void {
    const status: std.http.Status = @enumFromInt(resp.status);
    try ctx.respond(resp.body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = resp.content_type },
            .{ .name = "x-amzn-requestid", .value = &req.request_id },
        },
    });
}

fn mapEnvelopeError(ctx: *server.Context, err: anyerror) !void {
    switch (err) {
        error.MethodNotAllowed => return ctx.text(.method_not_allowed, "Method Not Allowed"),
        error.MissingAuth => return ctx.text(.forbidden, "Missing Authentication Token"),
        error.UnsupportedContentType => return ctx.text(.unsupported_media_type, "Unsupported Content-Type"),
        error.MissingTarget, error.MalformedTarget => return ctx.text(.bad_request, "Missing or malformed X-Amz-Target"),
        error.MissingAction => return ctx.text(.bad_request, "Missing Action parameter"),
        else => return err,
    }
}

pub fn echo(rt: *Runtime, req: *const envelope.Request) anyerror!Response {
    _ = rt;
    return .{
        .status = 200,
        .body = req.body,
        .content_type = switch (req.protocol) {
            .json => handler_mod.json_content_type,
            .query => handler_mod.xml_content_type,
        },
    };
}

const testing = std.testing;

test "table register and get" {
    var t: Table = .{};
    defer t.actions.deinit(testing.allocator);
    try t.register(testing.allocator, "Echo", echo);
    try testing.expect(t.get("Echo") != null);
    try testing.expect(t.get("Nope") == null);
}
