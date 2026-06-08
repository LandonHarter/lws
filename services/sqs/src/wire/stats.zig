const std = @import("std");
const server = @import("server");
const build_options = @import("build_options");
const Runtime = @import("../runtime.zig").Runtime;

pub fn handle(ctx: *server.Context, rt: *Runtime) !void {
    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const per_queue = try rt.registry.stats(a);

    var total_visible: u64 = 0;
    var total_in_flight: u64 = 0;
    var total_delayed: u64 = 0;
    for (per_queue) |q| {
        total_visible += q.visible;
        total_in_flight += q.in_flight;
        total_delayed += q.delayed;
    }

    const uptime_ms: i64 = if (rt.started_at_ms != 0) rt.clock.nowMs() - rt.started_at_ms else 0;

    var aw = std.Io.Writer.Allocating.init(a);
    const w = &aw.writer;

    try w.print(
        "{{\"service\":\"sqs\",\"version\":\"{s}\",\"uptime_ms\":{d},\"queues\":{d}," ++
            "\"messages\":{{\"visible\":{d},\"in_flight\":{d},\"delayed\":{d}}},\"detail\":[",
        .{ build_options.version, uptime_ms, per_queue.len, total_visible, total_in_flight, total_delayed },
    );
    for (per_queue, 0..) |q, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.print(
            "{{\"name\":\"{s}\",\"kind\":\"{s}\",\"visible\":{d},\"in_flight\":{d},\"delayed\":{d}}}",
            .{ q.name, @tagName(q.kind), q.visible, q.in_flight, q.delayed },
        );
    }
    try w.writeAll("]}");

    try ctx.json(.ok, aw.written());
}
