const std = @import("std");
const zli = @import("zli");

const root_dir = @import("../core/root_dir.zig");
const instances = @import("../core/instances.zig");

const service_flag = zli.Flag{
    .name = "service",
    .shortcut = "s",
    .description = "Service name, to disambiguate when an instance name is shared across services",
    .type = .String,
    .default_value = .{ .String = "" },
};

const force_flag = zli.Flag{
    .name = "force",
    .shortcut = "f",
    .description = "Send SIGKILL instead of SIGTERM",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "stop",
        .description = "Stop a running instance, keeping its registration, data, and config",
    }, stop);

    try cmd.addFlag(service_flag);
    try cmd.addFlag(force_flag);
    try cmd.addPositionalArg(.{
        .name = "name",
        .description = "Instance name to stop",
        .required = true,
    });

    return cmd;
}

pub fn stop(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const out = ctx.writer;

    const name = ctx.getArg("name") orelse {
        try out.print("missing instance name\n", .{});
        return;
    };
    const service_filter = ctx.flag("service", []const u8);
    const force = ctx.flag("force", bool);

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
        const sig: std.posix.SIG = if (force) .KILL else .TERM;
        instances.signal(inst.pid, sig) catch |err| {
            try out.print("failed to signal pid {d}: {s}\n", .{ inst.pid, @errorName(err) });
            return;
        };
        try out.print("stopped {s} instance '{s}' (pid {d})\n", .{ inst.service, inst.name, inst.pid });
    } else {
        try out.print("{s} instance '{s}' was not running\n", .{ inst.service, inst.name });
    }

    try instances.write(allocator, io, root, inst.service, inst.name, 0, inst.port, .stopped);
}
