const std = @import("std");
const zli = @import("zli");

const services = @import("../services.zig");
const root_dir = @import("../core/root_dir.zig");
const namegen = @import("../core/namegen.zig");
const instances = @import("../core/instances.zig");

const port_flag = zli.Flag{
    .name = "port",
    .shortcut = "p",
    .description = "Port to bind the service to (defaults to the service's standard port)",
    .type = .Int,
    .default_value = .{ .Int = 0 },
};

const name_flag = zli.Flag{
    .name = "name",
    .shortcut = "n",
    .description = "Instance name (defaults to a generated name); data lives in .lws/<service>/<name>",
    .type = .String,
    .default_value = .{ .String = "" },
};

const config_flag = zli.Flag{
    .name = "config",
    .shortcut = "c",
    .description = "Path to a JSON config file for the service (resolved relative to the current directory)",
    .type = .String,
    .default_value = .{ .String = "" },
};

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "run",
        .description = "Build and run a single service",
    }, run);

    try cmd.addFlag(port_flag);
    try cmd.addFlag(name_flag);
    try cmd.addFlag(config_flag);
    try cmd.addPositionalArg(.{
        .name = "service",
        .description = "Name of the service to run",
        .required = true,
    });

    return cmd;
}

fn run(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const out = ctx.writer;

    const name = ctx.getArg("service") orelse {
        try out.print("missing service name\n", .{});
        return;
    };

    const spec = services.find(name) orelse {
        try out.print("unknown service '{s}'\n", .{name});
        return;
    };

    const port_flag_val = ctx.flag("port", i32);
    const port: u16 = if (port_flag_val == 0) spec.default_port else @intCast(port_flag_val);

    const name_flag_val = ctx.flag("name", []const u8);
    const instance = if (name_flag_val.len == 0) try namegen.generate(allocator, io) else name_flag_val;
    defer if (name_flag_val.len == 0) allocator.free(instance);

    const config_path = ctx.flag("config", []const u8);

    const root = try root_dir.find(allocator, io);
    defer allocator.free(root);

    if (try instanceAlive(allocator, io, root, spec.name, instance)) {
        try out.print("instance '{s}' of {s} already running\n", .{ instance, spec.name });
        return;
    }

    const service_dir = try std.fs.path.join(allocator, &.{ root, spec.dir });
    defer allocator.free(service_dir);

    const data_dir = try std.fs.path.join(allocator, &.{ root, ".lws", spec.name, instance });
    defer allocator.free(data_dir);

    const bin_path = try std.fs.path.join(allocator, &.{ service_dir, "zig-out", "bin", spec.bin });
    defer allocator.free(bin_path);

    try out.print("building {s}...\n", .{spec.name});
    try out.flush();
    try spawnAndWait(io, &.{ "zig", "build" }, .{ .path = service_dir });

    try std.Io.Dir.createDirPath(.cwd(), io, data_dir);

    var effective_config: []const u8 = config_path;
    const persisted_config = try std.fs.path.join(allocator, &.{ data_dir, "config.json" });
    defer allocator.free(persisted_config);
    if (config_path.len > 0) {
        const raw_config = try std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .unlimited);
        defer allocator.free(raw_config);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = persisted_config, .data = raw_config });
        effective_config = persisted_config;
    }

    const log_path = try std.fs.path.join(allocator, &.{ data_dir, "output.log" });
    defer allocator.free(log_path);

    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_str);

    const log_file = try std.Io.Dir.createFileAbsolute(io, log_path, .{});
    defer log_file.close(io);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ bin_path, "--port", port_str, "--data-dir", data_dir });
    if (effective_config.len > 0) {
        try argv.appendSlice(allocator, &.{ "--config", effective_config });
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

    try instances.write(allocator, io, root, spec.name, instance, pid, port, .running);

    try out.print("started {s} instance '{s}' (pid {d}) on port {d}\n", .{ spec.name, instance, pid, port });
    try out.print("logs: {s}\n", .{log_path});
}

fn instanceAlive(allocator: std.mem.Allocator, io: std.Io, root: []const u8, service: []const u8, name: []const u8) !bool {
    const list = try instances.list(allocator, io, root);
    defer instances.freeList(allocator, list);
    for (list) |inst| {
        if (std.mem.eql(u8, inst.service, service) and std.mem.eql(u8, inst.name, name)) {
            return instances.alive(inst.pid);
        }
    }
    return false;
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
