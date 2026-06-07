const std = @import("std");
const server = @import("server");
const Runtime = @import("../runtime.zig").Runtime;

pub fn handle(ctx: *server.Context, rt: *Runtime) !void {
    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const uptime_ms: i64 = if (rt.started_at_ms != 0) rt.clock.nowMs() - rt.started_at_ms else 0;
    const stats = try rt.registry.aggregateStats(a);

    var aw = std.Io.Writer.Allocating.init(a);
    const w = &aw.writer;

    try w.print(
        "{{\"service\":\"dynamodb\",\"uptime_ms\":{d},\"tables\":{d},\"items\":{d},\"bytes\":{d},\"detail\":[",
        .{ uptime_ms, stats.tables, stats.items, stats.bytes },
    );
    for (stats.detail, 0..) |d, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"name\":", .{});
        try writeJsonString(w, d.name);
        try w.print(",\"items\":{d},\"bytes\":{d}}}", .{ d.items, d.bytes });
    }
    try w.writeAll("]}");

    try ctx.json(.ok, aw.written());
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c);
            },
        }
    }
    try w.writeByte('"');
}
