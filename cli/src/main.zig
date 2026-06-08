const std = @import("std");
const Io = std.Io;

const cli = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var wbuf: [1024]u8 = undefined;
    var stdout_writer = Io.File.Writer.init(.stdout(), io, &wbuf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var rbuf: [1024]u8 = undefined;
    var stdin_reader = Io.File.Reader.init(.stdin(), io, &rbuf);
    const stdin = &stdin_reader.interface;

    const root = try cli.build(.{
        .allocator = init.gpa,
        .io = io,
        .writer = stdout,
        .reader = stdin,
    });
    defer root.deinit();

    var argsIter = init.minimal.args.iterate();
    try root.execute(&argsIter, .{ .data = init.environ_map });
}
