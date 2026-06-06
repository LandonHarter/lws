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

const once_flag = zli.Flag{
    .name = "once",
    .shortcut = "o",
    .description = "Print the current log contents and exit instead of following",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "logs",
        .description = "Stream logs from a running service instance",
    }, logs);

    try cmd.addFlag(service_flag);
    try cmd.addFlag(once_flag);
    try cmd.addPositionalArg(.{
        .name = "name",
        .description = "Instance name to stream logs from",
        .required = true,
    });

    return cmd;
}

fn logs(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const out = ctx.writer;

    const name = ctx.getArg("name") orelse {
        try out.print("missing instance name\n", .{});
        return;
    };
    const service_filter = ctx.flag("service", []const u8);
    const once = ctx.flag("once", bool);

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

    const log_path = try std.fs.path.join(allocator, &.{ root, ".lws", inst.service, inst.name, "output.log" });
    defer allocator.free(log_path);

    const file = std.Io.Dir.openFileAbsolute(io, log_path, .{}) catch {
        try out.print("no log file for {s} instance '{s}' ({s})\n", .{ inst.service, inst.name, log_path });
        return;
    };
    defer file.close(io);

    var offset = try pump(io, out, file, 0);

    if (once) return;

    while (true) {
        std.Io.sleep(io, .fromMilliseconds(250), .awake) catch return;

        const st = file.stat(io) catch continue;
        if (st.size < offset) offset = 0;
        if (st.size != offset) offset = try pump(io, out, file, offset);
    }
}

fn pump(io: std.Io, out: *std.Io.Writer, file: std.Io.File, start: u64) !u64 {
    var buf: [4096]u8 = undefined;
    var pos = start;
    while (true) {
        const n = try file.readPositionalAll(io, &buf, pos);
        if (n == 0) break;
        try out.writeAll(buf[0..n]);
        pos += n;
        if (n < buf.len) break;
    }
    try out.flush();
    return pos;
}
