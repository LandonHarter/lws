const std = @import("std");
const server = @import("server");
const Runtime = @import("../runtime.zig").Runtime;

pub fn handle(ctx: *server.Context, rt: *Runtime) !void {
    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const uptime_ms: i64 = if (rt.started_at_ms != 0) rt.clock.nowMs() - rt.started_at_ms else 0;

    var aw = std.Io.Writer.Allocating.init(a);
    const w = &aw.writer;

    try w.print(
        "{{\"service\":\"s3\",\"uptime_ms\":{d},\"buckets\":{d}," ++
            "\"objects\":{d},\"bytes\":{d},\"detail\":[",
        .{ uptime_ms, @as(usize, 0), @as(u64, 0), @as(u64, 0) },
    );
    try w.writeAll("]}");

    try ctx.json(.ok, aw.written());
}
