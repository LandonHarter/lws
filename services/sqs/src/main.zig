const std = @import("std");

const Config = struct {
    port: u16 = 9324,
    data_dir: []const u8 = ".lws/sqs",
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();

    var cfg: Config = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args.next() orelse return error.MissingPortValue;
            cfg.port = try std.fmt.parseInt(u16, val, 10);
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            cfg.data_dir = args.next() orelse return error.MissingDataDirValue;
        } else {
            std.debug.print("sqs: unknown arg '{s}'\n", .{arg});
            return error.UnknownArg;
        }
    }

    std.debug.print("sqs (stub) listening on port {d}, data-dir '{s}'\n", .{ cfg.port, cfg.data_dir });

    while (true) {
        try std.Io.sleep(init.io, .fromSeconds(3600), .awake);
    }
}
