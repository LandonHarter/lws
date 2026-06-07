const std = @import("std");
const json_proto = @import("wire/json_proto.zig");

pub const Code = enum {
    validation_exception,
    resource_not_found_exception,
    resource_in_use_exception,
    conditional_check_failed_exception,
    transaction_canceled_exception,
    item_collection_size_limit_exceeded,
    request_limit_exceeded,
    provisioned_throughput_exceeded,
    limit_exceeded,
    internal_server_error,
    unknown_operation,
    serialization_exception,
};

// Fully-qualified `__type` value. UnknownOperation and Serialization live in the
// coral service namespace on the real service; the rest are dynamodb v20120810.
pub fn typeName(c: Code) []const u8 {
    return switch (c) {
        .validation_exception => "com.amazonaws.dynamodb.v20120810#ValidationException",
        .resource_not_found_exception => "com.amazonaws.dynamodb.v20120810#ResourceNotFoundException",
        .resource_in_use_exception => "com.amazonaws.dynamodb.v20120810#ResourceInUseException",
        .conditional_check_failed_exception => "com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException",
        .transaction_canceled_exception => "com.amazonaws.dynamodb.v20120810#TransactionCanceledException",
        .item_collection_size_limit_exceeded => "com.amazonaws.dynamodb.v20120810#ItemCollectionSizeLimitExceededException",
        .request_limit_exceeded => "com.amazonaws.dynamodb.v20120810#RequestLimitExceeded",
        .provisioned_throughput_exceeded => "com.amazonaws.dynamodb.v20120810#ProvisionedThroughputExceededException",
        .limit_exceeded => "com.amazonaws.dynamodb.v20120810#LimitExceededException",
        .internal_server_error => "com.amazonaws.dynamodb.v20120810#InternalServerError",
        .unknown_operation => "com.amazon.coral.service#UnknownOperationException",
        .serialization_exception => "com.amazon.coral.service#SerializationException",
    };
}

pub fn httpStatus(c: Code) u16 {
    return switch (c) {
        .internal_server_error => 500,
        else => 400,
    };
}

pub fn defaultMessage(c: Code) []const u8 {
    return switch (c) {
        .validation_exception => "The request was invalid.",
        .resource_not_found_exception => "Requested resource not found.",
        .resource_in_use_exception => "The resource is in use.",
        .conditional_check_failed_exception => "The conditional request failed.",
        .transaction_canceled_exception => "Transaction cancelled.",
        .item_collection_size_limit_exceeded => "Item collection size limit exceeded.",
        .request_limit_exceeded => "Request limit exceeded.",
        .provisioned_throughput_exceeded => "Provisioned throughput exceeded.",
        .limit_exceeded => "Limit exceeded.",
        .internal_server_error => "Internal server error.",
        .unknown_operation => "operation not yet implemented",
        .serialization_exception => "The request body could not be parsed.",
    };
}

// {"__type":"...","message":"...","Message":"..."} — both casings for SDK compat.
pub fn render(arena: std.mem.Allocator, c: Code, msg: []const u8) ![]const u8 {
    var w = json_proto.Writer.init(arena);
    try w.beginObject();
    try w.writeKey("__type");
    try w.writeString(typeName(c));
    try w.writeKey("message");
    try w.writeString(msg);
    try w.writeKey("Message");
    try w.writeString(msg);
    try w.endObject();
    return w.finish();
}

const testing = std.testing;

test "render emits both message casings and escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try render(arena.allocator(), .validation_exception, "bad \"x\"");
    try testing.expectEqualStrings(
        "{\"__type\":\"com.amazonaws.dynamodb.v20120810#ValidationException\"," ++
            "\"message\":\"bad \\\"x\\\"\",\"Message\":\"bad \\\"x\\\"\"}",
        s,
    );
}

test "status mapping" {
    try testing.expectEqual(@as(u16, 500), httpStatus(.internal_server_error));
    try testing.expectEqual(@as(u16, 400), httpStatus(.validation_exception));
    try testing.expectEqual(@as(u16, 400), httpStatus(.unknown_operation));
}

test "every code renders without error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    inline for (std.meta.tags(Code)) |c| {
        const s = try render(arena.allocator(), c, defaultMessage(c));
        try testing.expect(std.mem.indexOf(u8, s, "__type") != null);
    }
}
