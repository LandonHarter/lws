const std = @import("std");

pub const Level = enum {
    err,
    warn,
    info,
    debug,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warn",
            .info => "info",
            .debug => "debug",
        };
    }

    pub fn parse(s: []const u8) ?Level {
        if (std.mem.eql(u8, s, "error") or std.mem.eql(u8, s, "err")) return .err;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "debug")) return .debug;
        return null;
    }
};

pub const Logger = struct {
    threshold: Level = .info,

    pub fn enabled(self: Logger, level: Level) bool {
        return @intFromEnum(level) <= @intFromEnum(self.threshold);
    }

    pub fn log(self: Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (!self.enabled(level)) return;
        std.debug.print("[{s}] " ++ fmt ++ "\n", .{level.label()} ++ args);
    }

    pub fn err(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    pub fn warn(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn debug(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }
};

const testing = std.testing;

test "level parse" {
    try testing.expectEqual(Level.err, Level.parse("error").?);
    try testing.expectEqual(Level.warn, Level.parse("warn").?);
    try testing.expectEqual(Level.info, Level.parse("info").?);
    try testing.expectEqual(Level.debug, Level.parse("debug").?);
    try testing.expectEqual(@as(?Level, null), Level.parse("bogus"));
}

test "threshold gating" {
    const l: Logger = .{ .threshold = .warn };
    try testing.expect(l.enabled(.err));
    try testing.expect(l.enabled(.warn));
    try testing.expect(!l.enabled(.info));
    try testing.expect(!l.enabled(.debug));
}
