const std = @import("std");
const zli = @import("zli");

const root_dir = @import("../core/root_dir.zig");
const instances = @import("../core/instances.zig");
const http = @import("../core/http.zig");

const service_flag = zli.Flag{
    .name = "service",
    .shortcut = "s",
    .description = "Service name, to disambiguate when an instance name is shared across services",
    .type = .String,
    .default_value = .{ .String = "" },
};

const json_flag = zli.Flag{
    .name = "json",
    .shortcut = "j",
    .description = "Emit a single JSON object (metadata + service stats), for dashboards",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "info",
        .description = "Show metadata and live stats for a running service instance",
    }, info);

    try cmd.addFlag(service_flag);
    try cmd.addFlag(json_flag);
    try cmd.addPositionalArg(.{
        .name = "name",
        .description = "Instance name to inspect",
        .required = true,
    });

    return cmd;
}

fn info(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const out = ctx.writer;

    const name = ctx.getArg("name") orelse {
        try out.print("missing instance name\n", .{});
        return;
    };
    const service_filter = ctx.flag("service", []const u8);
    const as_json = ctx.flag("json", bool);

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
    const running = instances.alive(inst.pid);

    var stats_body: ?[]u8 = null;
    defer if (stats_body) |b| allocator.free(b);
    if (running) {
        stats_body = http.get(allocator, io, "127.0.0.1", inst.port, "/stats") catch null;
    }

    const pid_u: u32 = @intCast(inst.pid);

    if (as_json) {
        try out.print(
            "{{\"service\":\"{s}\",\"name\":\"{s}\",\"pid\":{d},\"port\":{d},\"alive\":{s},\"stats\":{s}}}\n",
            .{ inst.service, inst.name, pid_u, inst.port, if (running) "true" else "false", stats_body orelse "null" },
        );
        return;
    }

    try out.print("service   {s}\n", .{inst.service});
    try out.print("name      {s}\n", .{inst.name});
    try out.print("pid       {d}\n", .{pid_u});
    try out.print("port      {d}\n", .{inst.port});
    try out.print("status    {s}\n", .{if (running) "running" else "dead"});
    if (running) {
        if (stats_body) |b| {
            try out.print("stats     {s}\n", .{b});
        } else {
            try out.print("stats     <unavailable>\n", .{});
        }
    }
}
