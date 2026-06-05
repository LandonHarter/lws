pub const ServiceSpec = struct {
    name: []const u8,
    dir: []const u8,
    bin: []const u8,
    default_port: u16,
    description: []const u8,
};

pub const registry = [_]ServiceSpec{
    .{
        .name = "sqs",
        .dir = "services/sqs",
        .bin = "sqs",
        .default_port = 9324,
        .description = "Simple Queue Service",
    },
};

pub fn find(name: []const u8) ?ServiceSpec {
    const std = @import("std");
    for (registry) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}
