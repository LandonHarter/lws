const std = @import("std");
const zli = @import("zli");

const services = @import("../services.zig");
const root_dir = @import("../core/root_dir.zig");
const namegen = @import("../core/namegen.zig");

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

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "run",
        .description = "Build and run a single service",
    }, run);

    try cmd.addFlag(port_flag);
    try cmd.addFlag(name_flag);
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

    const root = try root_dir.find(allocator, io);
    defer allocator.free(root);

    const service_dir = try std.fs.path.join(allocator, &.{ root, spec.dir });
    defer allocator.free(service_dir);

    const data_dir = try std.fs.path.join(allocator, &.{ root, ".lws", spec.name, instance });
    defer allocator.free(data_dir);

    const bin_path = try std.fs.path.join(allocator, &.{ service_dir, "zig-out", "bin", spec.bin });
    defer allocator.free(bin_path);

    try out.print("building {s}...\n", .{spec.name});
    try out.flush();
    try spawnAndWait(io, &.{ "zig", "build" }, .{ .path = service_dir });

    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_str);

    try out.print("starting {s} instance '{s}' on port {d}\n", .{ spec.name, instance, port });
    try out.flush();
    try spawnAndWait(io, &.{ bin_path, "--port", port_str, "--data-dir", data_dir }, .inherit);
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
