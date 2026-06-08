const std = @import("std");
const zli = @import("zli");

const services = @import("../services.zig");
const root_dir = @import("../core/root_dir.zig");
const instances = @import("../core/instances.zig");
const bin_resolver = @import("../core/bin_resolver.zig");

const service_flag = zli.Flag{
    .name = "service",
    .shortcut = "s",
    .description = "Service name, to disambiguate when an instance name is shared across services",
    .type = .String,
    .default_value = .{ .String = "" },
};

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "start",
        .description = "Revive a stopped instance on its original port, config, and data",
    }, start);

    try cmd.addFlag(service_flag);
    try cmd.addPositionalArg(.{
        .name = "name",
        .description = "Instance name to start",
        .required = true,
    });

    return cmd;
}

fn start(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const out = ctx.writer;
    const env_map: ?*const std.process.Environ.Map = if (ctx.data) |d| @ptrCast(@alignCast(d)) else null;

    const name = ctx.getArg("name") orelse {
        try out.print("missing instance name\n", .{});
        return;
    };
    const service_filter = ctx.flag("service", []const u8);

    const root = try root_dir.find(allocator, io);
    defer allocator.free(root);

    const items = try instances.list(allocator, io, root);
    defer instances.freeList(allocator, items);

    var match: ?instances.Instance = null;
    var match_count: usize = 0;
    for (items) |inst| {
        if (!std.mem.eql(u8, inst.name, name)) continue;
        if (service_filter.len != 0 and !std.mem.eql(u8, inst.service, service_filter)) continue;
        match = inst;
        match_count += 1;
    }

    if (match_count == 0) {
        try out.print("no instance named '{s}'\n", .{name});
        return;
    }
    if (match_count > 1) {
        try out.print("'{s}' matches multiple services; pass --service to disambiguate\n", .{name});
        return;
    }

    const inst = match.?;
    if (instances.alive(inst.pid)) {
        try out.print("{s} instance '{s}' already running (pid {d})\n", .{ inst.service, inst.name, inst.pid });
        return;
    }

    const spec = services.find(inst.service) orelse {
        try out.print("unknown service '{s}'\n", .{inst.service});
        return;
    };

    const data_dir = try std.fs.path.join(allocator, &.{ root, ".lws", spec.name, inst.name });
    defer allocator.free(data_dir);

    const resolved = bin_resolver.resolve(allocator, io, env_map, spec.name, spec.bin) catch |err| switch (err) {
        error.ServiceBinaryNotFound => {
            try out.print(
                "could not find {s} binary to revive instance '{s}'. Tried: $LWS_BIN_DIR, dir of lws executable, ./services/{s}/zig-out/bin/. " ++
                    "If you installed lws, reinstall. If you're on the source tree, run `cd services/{s} && zig build`.\n",
                .{ spec.bin, inst.name, spec.name, spec.name },
            );
            return;
        },
        else => return err,
    };
    defer allocator.free(resolved.path);
    const bin_path = resolved.path;

    try std.Io.Dir.createDirPath(.cwd(), io, data_dir);

    const config_path = try std.fs.path.join(allocator, &.{ data_dir, "config.json" });
    defer allocator.free(config_path);
    const has_config = blk: {
        std.Io.Dir.accessAbsolute(io, config_path, .{}) catch break :blk false;
        break :blk true;
    };

    const log_path = try std.fs.path.join(allocator, &.{ data_dir, "output.log" });
    defer allocator.free(log_path);

    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{inst.port});
    defer allocator.free(port_str);

    const log_file = try std.Io.Dir.createFileAbsolute(io, log_path, .{});
    defer log_file.close(io);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ bin_path, "--port", port_str, "--data-dir", data_dir });
    if (has_config) {
        try argv.appendSlice(allocator, &.{ "--config", config_path });
    }

    const child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .inherit,
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
        .pgid = 0,
    });
    const pid = child.id orelse return error.SpawnFailed;

    try instances.write(allocator, io, root, spec.name, inst.name, pid, inst.port, .running);

    try out.print("started {s} instance '{s}' (pid {d}) on port {d}\n", .{ spec.name, inst.name, pid, inst.port });
    try out.print("logs: {s}\n", .{log_path});
}
