const std = @import("std");

// Whole-file replace: write to <path>.tmp, fsync, then rename over <path>.
// DynamoDB item writes are whole-item replace, so no WAL is needed. A crash
// leaves at most a stale *.tmp that the next write overwrites (recovery ignores
// them).
pub fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8, fsync: bool) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&buf, "{s}.tmp", .{path});
    {
        var file = try std.Io.Dir.cwd().createFile(io, tmp, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        if (fsync) try file.sync(io);
    }
    try std.Io.Dir.cwd().rename(tmp, .cwd(), path, io);
}

const testing = std.testing;

test "writeAtomic writes bytes then renames into place" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.Io.Dir.createDirPath(.cwd(), io, dir);
    const path = try std.fs.path.join(arena, &.{ dir, "f" });

    try writeAtomic(io, path, "hello", false);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, std.Io.Limit.limited(64));
    try testing.expectEqualStrings("hello", got);

    const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, tmp_path, .{}));
}
