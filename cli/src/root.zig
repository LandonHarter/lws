const std = @import("std");
const zli = @import("zli");

const version = @import("commands/version.zig");
const run = @import("commands/run.zig");
const list = @import("commands/list.zig");
const kill = @import("commands/kill.zig");

pub fn build(init_options: zli.InitOptions) !*zli.Command {
    const root = try zli.Command.init(init_options, .{
        .name = "LWS CLI",
        .description = "LWS command line interface",
        .version = .{ .major = 0, .minor = 0, .patch = 1, .pre = null, .build = null },
    }, showHelp);

    try root.addCommands(&.{
        try version.register(init_options),
        try run.register(init_options),
        try list.register(init_options),
        try kill.register(init_options),
    });

    return root;
}

fn showHelp(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
}
