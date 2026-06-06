const std = @import("std");
const server = @import("server");
const Runtime = @import("../runtime.zig").Runtime;
const stats = @import("stats.zig");

// Phase 1 stub. Replaced by full REST routing in Phase 2.
pub fn handleHttp(ctx: *server.Context) !void {
    const rt: *Runtime = ctx.userData(Runtime);

    if (ctx.method() == .GET and std.mem.eql(u8, ctx.path(), "/health")) {
        return ctx.json(.ok, "{\"status\":\"ok\"}");
    }

    if (ctx.method() == .GET and std.mem.eql(u8, ctx.path(), "/stats")) {
        return stats.handle(ctx, rt);
    }

    const body =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" ++
        "<Error><Code>NotImplemented</Code>" ++
        "<Message>A header you provided implies functionality that is not implemented</Message>" ++
        "<HostId>lws</HostId></Error>";
    try ctx.respond(body, .{
        .status = .not_implemented,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/xml" },
            .{ .name = "x-amz-id-2", .value = "lws" },
        },
    });
}
