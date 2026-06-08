const std = @import("std");
const zli = @import("zli");

const services = @import("../services.zig");
const bin_resolver = @import("../core/bin_resolver.zig");

const output_flag = zli.Flag{
    .name = "output",
    .shortcut = "o",
    .description = "Path to write the generated config (defaults to stdout)",
    .type = .String,
    .default_value = .{ .String = "" },
};

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "config",
        .description = "Work with service config files",
    }, showHelp);

    try cmd.addCommands(&.{
        try registerGenerate(init_options),
    });

    return cmd;
}

fn showHelp(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
}

fn registerGenerate(init_options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "generate",
        .description = "Generate a default config file for a service",
    }, generate);

    try cmd.addFlag(output_flag);
    try cmd.addPositionalArg(.{
        .name = "service",
        .description = "Name of the service to generate a config for",
        .required = true,
    });

    return cmd;
}

fn generate(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const out = ctx.writer;
    const env_map: ?*const std.process.Environ.Map = if (ctx.data) |d| @ptrCast(@alignCast(d)) else null;

    const name = ctx.getArg("service") orelse {
        try out.print("missing service name\n", .{});
        return;
    };

    const spec = services.find(name) orelse {
        try out.print("unknown service '{s}'\n", .{name});
        return;
    };

    const output = ctx.flag("output", []const u8);

    const resolved = bin_resolver.resolve(allocator, io, env_map, spec.name, spec.bin) catch |err| switch (err) {
        error.ServiceBinaryNotFound => {
            try out.print(
                "could not find {s} binary. Tried: $LWS_BIN_DIR, dir of lws executable, ./services/{s}/zig-out/bin/. " ++
                    "If you installed lws, reinstall. If you're on the source tree, run `cd services/{s} && zig build`.\n",
                .{ spec.bin, spec.name, spec.name },
            );
            return;
        },
        else => return err,
    };
    defer allocator.free(resolved.path);
    const bin_path = resolved.path;

    var stdout_target: std.process.SpawnOptions.StdIo = .inherit;
    var out_file: ?std.Io.File = null;
    if (output.len > 0) {
        out_file = try std.Io.Dir.cwd().createFile(io, output, .{});
        stdout_target = .{ .file = out_file.? };
    }
    defer if (out_file) |f| f.close(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{ bin_path, "--generate-config" },
        .cwd = .inherit,
        .stdin = .ignore,
        .stdout = stdout_target,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildTerminated,
    }

    if (output.len > 0) {
        try out.print("wrote {s} config to {s}\n", .{ spec.name, output });
    }
}
