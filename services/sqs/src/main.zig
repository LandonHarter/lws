const std = @import("std");
const server = @import("server");
const queue = @import("queue_config.zig");
const log = @import("core").log;

const Config = struct {
    port: u16 = 9324,
    bind: []const u8 = "127.0.0.1",
    data_dir: []const u8 = ".lws/sqs",
    config_path: []const u8 = "",
    generate_config: bool = false,
    account_id: []const u8 = "000000000000",
    region: []const u8 = "us-east-1",
    host: []const u8 = "",
    log_level: []const u8 = "info",
    fsync: bool = true,
};

const State = struct {
    cfg: Config,
    queue: ?queue.QueueConfig,
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
        } else if (std.mem.eql(u8, arg, "--generate-config")) {
            cfg.generate_config = true;
        } else if (std.mem.eql(u8, arg, "--bind")) {
            cfg.bind = args.next() orelse return error.MissingBindValue;
        } else if (std.mem.eql(u8, arg, "--account-id")) {
            cfg.account_id = args.next() orelse return error.MissingAccountIdValue;
        } else if (std.mem.eql(u8, arg, "--region")) {
            cfg.region = args.next() orelse return error.MissingRegionValue;
        } else if (std.mem.eql(u8, arg, "--host")) {
            cfg.host = args.next() orelse return error.MissingHostValue;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            cfg.log_level = args.next() orelse return error.MissingLogLevelValue;
        } else if (std.mem.eql(u8, arg, "--fsync")) {
            const val = args.next() orelse return error.MissingFsyncValue;
            if (std.mem.eql(u8, val, "off") or std.mem.eql(u8, val, "false")) {
                cfg.fsync = false;
            } else if (std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "true")) {
                cfg.fsync = true;
            } else {
                std.debug.print("sqs: invalid --fsync value '{s}' (want on|off)\n", .{val});
                return error.InvalidFsyncValue;
            }
        } else {
            std.debug.print("sqs: unknown arg '{s}'\n", .{arg});
            return error.UnknownArg;
        }
    }

    if (cfg.generate_config) {
        var wbuf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.Writer.init(.stdout(), init.io, &wbuf);
        const stdout = &stdout_writer.interface;
        try queue.writeDefaults(.standard, stdout);
        try stdout.flush();
        return;
    }

    if (log.Level.parse(cfg.log_level) == null) {
        std.debug.print("sqs: invalid --log-level '{s}' (want error|warn|info|debug)\n", .{cfg.log_level});
        return error.InvalidLogLevel;
    }

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    if (cfg.host.len == 0) {
        cfg.host = try std.fmt.allocPrint(arena.allocator(), "{s}:{d}", .{ cfg.bind, cfg.port });
    }

    var state: State = .{ .cfg = cfg, .queue = null };
    if (cfg.config_path.len > 0) {
        const q = queue.loadFile(arena.allocator(), init.io, cfg.config_path) catch std.process.exit(1);
        state.queue = q;
        std.debug.print("sqs: loaded {s} queue with {d} attribute(s) from '{s}'\n", .{ @tagName(q.kind), q.attributes.count(), cfg.config_path });
    }

    std.debug.print("sqs listening on {s}:{d} (host '{s}', account {s}, region {s}), data-dir '{s}'\n", .{ cfg.bind, cfg.port, cfg.host, cfg.account_id, cfg.region, cfg.data_dir });

    var srv = try server.Server.init(init.io, init.gpa, .{ .port = cfg.port, .host = cfg.bind });
    defer srv.deinit();

    try srv.run(handle, &state);
}

fn handle(ctx: *server.Context) !void {
    if (ctx.method() == .GET and std.mem.eql(u8, ctx.path(), "/health")) {
        return ctx.json(.ok, "{\"status\":\"ok\"}");
    }
}
