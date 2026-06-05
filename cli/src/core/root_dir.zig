const std = @import("std");
const Io = std.Io;

const marker = ".lwsroot";

pub const Error = error{RootNotFound} || std.mem.Allocator.Error;

pub fn find(allocator: std.mem.Allocator, io: Io) ![]u8 {
    const start = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(start);

    var dir: []const u8 = start;
    while (true) {
        const probe = try std.fs.path.join(allocator, &.{ dir, marker });
        defer allocator.free(probe);

        if (std.Io.Dir.accessAbsolute(io, probe, .{})) {
            return allocator.dupe(u8, dir);
        } else |_| {}

        const parent = std.fs.path.dirname(dir) orelse return error.RootNotFound;
        if (parent.len == dir.len) return error.RootNotFound;
        dir = parent;
    }
}
