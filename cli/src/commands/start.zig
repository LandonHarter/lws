const std = @import("std");
const zli = @import("zli");

const services = @import("../services.zig");
const root_dir = @import("../core/root_dir.zig");
const instances = @import("../core/instances.zig");

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

    const service_dir = try std.fs.path.join(allocator, &.{ root, spec.dir });
    defer allocator.free(service_dir);

    const data_dir = try std.fs.path.join(allocator, &.{ root, ".lws", spec.name, inst.name });
    defer allocator.free(data_dir);

    const bin_path = try std.fs.path.join(allocator, &.{ service_dir, "zig-out", "bin", spec.bin });
    defer allocator.free(bin_path);

    try out.print("building {s}...\n", .{spec.name});
    try out.flush();
    try spawnAndWait(io, &.{ "zig", "build" }, .{ .path = service_dir });

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

fn spawnAndWait(io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildTerminated,
    }
}
