const std = @import("std");
const zli = @import("zli");

const marker = ".lwsroot";

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    return zli.Command.init(init_options, .{
        .name = "init",
        .description = "Mark the current directory as a project root (creates a .lwsroot marker)",
    }, run);
}

fn run(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const out = ctx.writer;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const probe = try std.fs.path.join(allocator, &.{ cwd, marker });
    defer allocator.free(probe);

    if (std.Io.Dir.accessAbsolute(io, probe, .{})) {
        try out.print("already a project root: {s}\n", .{cwd});
        try out.flush();
        return;
    } else |_| {}

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "" });

    try out.print("initialized project root at {s}\n", .{cwd});
    try out.flush();
}
