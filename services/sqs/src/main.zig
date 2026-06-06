const std = @import("std");
const server = @import("server");
const queue = @import("queue_config.zig");
const log = @import("core").log;
const time = @import("core").time;
const Runtime = @import("runtime.zig").Runtime;
const dispatch = @import("wire/dispatch.zig");
const registry_mod = @import("registry.zig");
const queue_lifecycle = @import("handlers/queue_lifecycle.zig");
const queue_attrs = @import("handlers/queue_attrs.zig");
const messages = @import("handlers/messages.zig");
const batch = @import("handlers/batch.zig");
const Ticker = @import("ticker.zig").Ticker;

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

    std.debug.print("sqs listening on {s}:{d} (host '{s}', account {s}, region {s}), data-dir '{s}'\n", .{ cfg.bind, cfg.port, cfg.host, cfg.account_id, cfg.region, cfg.data_dir });

    const clock = time.Clock.real(init.io);
    const seed: u64 = @bitCast(clock.nowMs());
    var prng = std.Random.DefaultPrng.init(seed);

    var reg = registry_mod.Registry.init(init.gpa, init.io, cfg.data_dir, cfg.fsync, clock, prng.random());
    defer reg.deinit();
    try reg.recover();

    var rt: Runtime = .{
        .gpa = init.gpa,
        .io = init.io,
        .clock = clock,
        .account = cfg.account_id,
        .region = cfg.region,
        .host = cfg.host,
        .data_dir = cfg.data_dir,
        .fsync = cfg.fsync,
        .logger = .{ .threshold = log.Level.parse(cfg.log_level).? },
        .rng = prng.random(),
        .registry = &reg,
    };

    try dispatch.table.register(init.gpa, "Echo", dispatch.echo);
    try queue_lifecycle.register(init.gpa);
    try queue_attrs.register(init.gpa);
    try messages.register(init.gpa);
    try batch.register(init.gpa);

    if (cfg.config_path.len > 0) {
        const loaded = queue.loadFile(arena.allocator(), init.io, cfg.config_path) catch std.process.exit(1);
        const name = loaded.name orelse std.fs.path.stem(std.fs.path.basename(cfg.config_path));
        if (reg.get(name) == null) {
            var raw_attrs: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
            var it = loaded.attributes.iterator();
            while (it.next()) |e| {
                const raw = switch (e.value_ptr.*) {
                    .integer => |n| try std.fmt.allocPrint(arena.allocator(), "{d}", .{n}),
                    .boolean => |b| if (b) "true" else "false",
                    .string => |s| s,
                    .json => |j| j,
                };
                try raw_attrs.put(arena.allocator(), e.key_ptr.*, raw);
            }
            var no_tags: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
            _ = reg.create(name, &raw_attrs, &no_tags) catch |err| {
                std.debug.print("sqs: failed to pre-seed queue '{s}': {s}\n", .{ name, @errorName(err) });
                std.process.exit(1);
            };
            std.debug.print("sqs: pre-seeded queue '{s}' ({s})\n", .{ name, @tagName(loaded.kind) });
        }
    }

    var ticker: Ticker = .{ .rt = &rt };
    try ticker.start();
    defer ticker.stop();

    var srv = try server.Server.init(init.io, init.gpa, .{ .port = cfg.port, .host = cfg.bind });
    defer srv.deinit();

    try srv.run(dispatch.handleHttp, &rt);
}
