const std = @import("std");
const log = @import("core").log;
const time = @import("core").time;
const Registry = @import("registry.zig").Registry;

pub const LogLevel = log.Level;

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: time.Clock = .{},
    account: []const u8 = "000000000000",
    region: []const u8 = "us-east-1",
    host: []const u8 = "127.0.0.1:9000",
    data_dir: []const u8 = ".lws/s3",
    fsync: bool = true,
    logger: log.Logger = .{},
    rng: std.Random,
    started_at_ms: i64 = 0,
    registry: *Registry = undefined,
};

const testing = std.testing;

test "runtime defaults" {
    var prng = std.Random.DefaultPrng.init(0);
    const rt: Runtime = .{ .gpa = testing.allocator, .io = undefined, .rng = prng.random() };
    try testing.expectEqualStrings("000000000000", rt.account);
    try testing.expectEqualStrings("us-east-1", rt.region);
    try testing.expect(rt.fsync);
    try testing.expectEqual(LogLevel.info, rt.logger.threshold);
}
