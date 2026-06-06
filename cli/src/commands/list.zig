const std = @import("std");
const zli = @import("zli");

const root_dir = @import("../core/root_dir.zig");
const instances = @import("../core/instances.zig");

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    return zli.Command.init(init_options, .{
        .name = "list",
        .shortcut = "ls",
        .description = "List running service instances",
    }, list);
}

fn list(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const out = ctx.writer;

    const root = try root_dir.find(allocator, io);
    defer allocator.free(root);

    const items = try instances.list(allocator, io, root);
    defer instances.freeList(allocator, items);

    if (items.len == 0) {
        try out.print("no instances\n", .{});
        return;
    }

    try out.print("{s:<10} {s:<24} {s:<8} {s:<6} {s}\n", .{ "SERVICE", "NAME", "PID", "PORT", "STATUS" });
    for (items) |inst| {
        const status = switch (inst.state) {
            .stopped => "stopped",
            .running => if (instances.alive(inst.pid)) "running" else "dead",
        };
        const pid_u: u32 = @intCast(inst.pid);
        try out.print("{s:<10} {s:<24} {d:<8} {d:<6} {s}\n", .{ inst.service, inst.name, pid_u, inst.port, status });
    }
}
