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
        .bin = "lws-sqs",
        .default_port = 9324,
        .description = "Simple Queue Service",
    },
    .{
        .name = "s3",
        .dir = "services/s3",
        .bin = "lws-s3",
        .default_port = 9000,
        .description = "Simple Storage Service",
    },
    .{
        .name = "dynamodb",
        .dir = "services/dynamodb",
        .bin = "lws-dynamodb",
        .default_port = 8000,
        .description = "Simple NoSQL Database (DynamoDB-compatible)",
    },
};

pub fn find(name: []const u8) ?ServiceSpec {
    const std = @import("std");
    for (registry) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}
