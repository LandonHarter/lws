const config = @import("config");
const AttrSpec = config.AttrSpec;

pub const queue_attrs = [_]AttrSpec{
    .{ .name = "Policy", .type = .json },
    .{ .name = "VisibilityTimeout", .type = .integer, .default = .{ .integer = 30 }, .min = 0, .max = 43200 },
    .{ .name = "MaximumMessageSize", .type = .integer, .default = .{ .integer = 1048576 }, .min = 1024, .max = 1048576 },
    .{ .name = "MessageRetentionPeriod", .type = .integer, .default = .{ .integer = 345600 }, .min = 60, .max = 1209600 },
    .{ .name = "DelaySeconds", .type = .integer, .default = .{ .integer = 0 }, .min = 0, .max = 900 },
    .{ .name = "ReceiveMessageWaitTimeSeconds", .type = .integer, .default = .{ .integer = 0 }, .min = 0, .max = 20 },
    .{ .name = "RedrivePolicy", .type = .json },
    .{ .name = "RedriveAllowPolicy", .type = .json },

    .{ .name = "FifoQueue", .type = .boolean, .default = .{ .boolean = false }, .mutability = .create_only },
    .{ .name = "ContentBasedDeduplication", .type = .boolean, .default = .{ .boolean = false }, .applies = .fifo_only },
    .{ .name = "DeduplicationScope", .type = .string, .default = .{ .string = "queue" }, .applies = .fifo_only, .allowed = &.{ "queue", "messageGroup" } },
    .{ .name = "FifoThroughputLimit", .type = .string, .default = .{ .string = "perQueue" }, .applies = .fifo_only, .allowed = &.{ "perQueue", "perMessageGroupId" } },

    .{ .name = "SqsManagedSseEnabled", .type = .boolean, .default = .{ .boolean = true } },
    .{ .name = "KmsMasterKeyId", .type = .string },
    .{ .name = "KmsDataKeyReusePeriodSeconds", .type = .integer, .default = .{ .integer = 300 }, .min = 60, .max = 86400 },

    .{ .name = "QueueArn", .type = .string, .mutability = .read_only },
    .{ .name = "CreatedTimestamp", .type = .integer, .mutability = .read_only },
    .{ .name = "LastModifiedTimestamp", .type = .integer, .mutability = .read_only },
    .{ .name = "ApproximateNumberOfMessages", .type = .integer, .mutability = .read_only },
    .{ .name = "ApproximateNumberOfMessagesNotVisible", .type = .integer, .mutability = .read_only },
    .{ .name = "ApproximateNumberOfMessagesDelayed", .type = .integer, .mutability = .read_only },
};

const std = @import("std");
const testing = std.testing;

test "table covers full attribute surface" {
    try testing.expectEqual(@as(usize, 21), queue_attrs.len);
}

test "FifoQueue is create-only" {
    const spec = config.lookup(&queue_attrs, "FifoQueue").?;
    try testing.expectEqual(config.Mutability.create_only, spec.mutability);
}

test "computed attrs are read-only with no default" {
    const spec = config.lookup(&queue_attrs, "ApproximateNumberOfMessages").?;
    try testing.expectEqual(config.Mutability.read_only, spec.mutability);
    try testing.expectEqual(@as(?config.Value, null), spec.default);
}

test "fifo_only attr rejected on standard queue" {
    try testing.expectError(config.Error.InvalidAttributeName, config.validateOne(&queue_attrs, .create, .standard, "ContentBasedDeduplication", "true"));
}

test "RedrivePolicy maxReceiveCount json passes through" {
    const v = try config.validateOne(&queue_attrs, .create, .standard, "RedrivePolicy", "{\"maxReceiveCount\":5}");
    try testing.expectEqualStrings("{\"maxReceiveCount\":5}", v.json);
}
