const std = @import("std");

// Zig 0.16 removed std.time.timestamp; wall-clock now comes from std.Io.Clock.
// Clock wraps an Io for real time, or holds fixed values for test injection.
pub const Clock = struct {
    io: std.Io = undefined,
    fixed_sec: ?i64 = null,
    fixed_ms: ?i64 = null,

    pub fn real(io: std.Io) Clock {
        return .{ .io = io };
    }

    pub fn fixed(sec: i64, ms: i64) Clock {
        return .{ .fixed_sec = sec, .fixed_ms = ms };
    }

    pub fn nowSec(self: Clock) i64 {
        if (self.fixed_sec) |s| return s;
        return std.Io.Clock.real.now(self.io).toSeconds();
    }

    pub fn nowMs(self: Clock) i64 {
        if (self.fixed_ms) |m| return m;
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }
};

const testing = std.testing;

test "real clock returns positive wall-clock seconds" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const c = Clock.real(threaded.io());
    try testing.expect(c.nowSec() > 1_600_000_000);
    try testing.expect(c.nowMs() > 0);
}

test "fixed clock is used" {
    const c = Clock.fixed(42, 4200);
    try testing.expectEqual(@as(i64, 42), c.nowSec());
    try testing.expectEqual(@as(i64, 4200), c.nowMs());
}
