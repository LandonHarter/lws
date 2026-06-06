const zli = @import("zli");

const stop = @import("stop.zig");

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
        .name = "kill",
        .description = "Alias for stop",
    }, stop.stop);

    try cmd.addFlag(service_flag);
    try cmd.addFlag(force_flag);
    try cmd.addPositionalArg(.{
        .name = "name",
        .description = "Instance name to stop",
        .required = true,
    });

    return cmd;
}
