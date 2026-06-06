const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const message_store = @import("store/message_store.zig");
const queue = @import("queue.zig");

const tick_interval_ms: i64 = 50;

pub const Ticker = struct {
    rt: *Runtime,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *Ticker) !void {
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    pub fn stop(self: *Ticker) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn loop(self: *Ticker) void {
        const io = self.rt.io;
        while (!self.stop_flag.load(.acquire)) {
            const now = self.rt.clock.nowMs();
            self.rt.registry.mutex.lockUncancelable(io);
            for (self.rt.registry.queues_by_name.values()) |q| {
                if (q.store) |s| {
                    const store: *message_store.Store = @ptrCast(@alignCast(s.ctx));
                    store.tick(now);
                }
            }
            self.rt.registry.mutex.unlock(io);
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(tick_interval_ms), .awake) catch {};
        }
    }
};
