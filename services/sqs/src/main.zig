const std = @import("std");
const server = @import("server");
const queue = @import("queue.zig");

const Config = struct {
    port: u16 = 9324,
    data_dir: []const u8 = ".lws/sqs",
    config_path: []const u8 = "",
};

const State = struct {
    cfg: Config,
    queue: ?queue.Queue,
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();

    var cfg: Config = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args.next() orelse return error.MissingPortValue;
            cfg.port = try std.fmt.parseInt(u16, val, 10);
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            cfg.data_dir = args.next() orelse return error.MissingDataDirValue;
        } else if (std.mem.eql(u8, arg, "--config")) {
            cfg.config_path = args.next() orelse return error.MissingConfigValue;
        } else {
            std.debug.print("sqs: unknown arg '{s}'\n", .{arg});
            return error.UnknownArg;
        }
    }

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    var state: State = .{ .cfg = cfg, .queue = null };
    if (cfg.config_path.len > 0) {
        const q = queue.loadFile(arena.allocator(), init.io, cfg.config_path) catch std.process.exit(1);
        state.queue = q;
        std.debug.print("sqs: loaded {s} queue with {d} attribute(s) from '{s}'\n", .{ @tagName(q.kind), q.attributes.count(), cfg.config_path });
    }

    std.debug.print("sqs listening on port {d}, data-dir '{s}'\n", .{ cfg.port, cfg.data_dir });

    var srv = try server.Server.init(init.io, init.gpa, .{ .port = cfg.port });
    defer srv.deinit();

    try srv.run(handle, &state);
}

fn handle(ctx: *server.Context) !void {
    if (ctx.method() == .GET and std.mem.eql(u8, ctx.path(), "/health")) {
        return ctx.json(.ok, "{\"status\":\"ok\"}");
    }
}
