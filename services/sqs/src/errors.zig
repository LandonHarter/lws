const std = @import("std");

pub const Code = enum {
    queue_does_not_exist,
    queue_name_exists,
    queue_deleted_recently,
    unsupported_operation,
    invalid_attribute_name,
    invalid_attribute_value,
    missing_required_parameter,
    invalid_parameter_value,
    receipt_handle_invalid,
    invalid_id_format,
    message_not_inflight,
    purge_queue_in_progress,
    empty_batch_request,
    too_many_entries_in_batch,
    batch_entry_ids_not_distinct,
    invalid_batch_entry_id,
    batch_request_too_long,
    over_limit,
    internal_error,
    unrecognized_action,
};

pub fn httpStatus(c: Code) u16 {
    return switch (c) {
        .receipt_handle_invalid => 404,
        .purge_queue_in_progress, .over_limit => 403,
        .internal_error => 500,
        else => 400,
    };
}

pub fn jsonType(c: Code) []const u8 {
    return switch (c) {
        .queue_does_not_exist => "com.amazonaws.sqs#QueueDoesNotExist",
        .queue_name_exists => "com.amazonaws.sqs#QueueNameExists",
        .queue_deleted_recently => "com.amazonaws.sqs#QueueDeletedRecently",
        .unsupported_operation => "com.amazonaws.sqs#UnsupportedOperation",
        .invalid_attribute_name => "com.amazonaws.sqs#InvalidAttributeName",
        .invalid_attribute_value => "com.amazonaws.sqs#InvalidAttributeValue",
        .missing_required_parameter => "com.amazonaws.sqs#MissingRequiredParameter",
        .invalid_parameter_value => "com.amazonaws.sqs#InvalidParameterValue",
        .receipt_handle_invalid => "com.amazonaws.sqs#ReceiptHandleIsInvalid",
        .invalid_id_format => "com.amazonaws.sqs#InvalidIdFormat",
        .message_not_inflight => "com.amazonaws.sqs#MessageNotInflight",
        .purge_queue_in_progress => "com.amazonaws.sqs#PurgeQueueInProgress",
        .empty_batch_request => "com.amazonaws.sqs#EmptyBatchRequest",
        .too_many_entries_in_batch => "com.amazonaws.sqs#TooManyEntriesInBatchRequest",
        .batch_entry_ids_not_distinct => "com.amazonaws.sqs#BatchEntryIdsNotDistinct",
        .invalid_batch_entry_id => "com.amazonaws.sqs#InvalidBatchEntryId",
        .batch_request_too_long => "com.amazonaws.sqs#BatchRequestTooLong",
        .over_limit => "com.amazonaws.sqs#OverLimit",
        .internal_error => "com.amazonaws.sqs#InternalError",
        .unrecognized_action => "com.amazonaws.sqs#InvalidAction",
    };
}

pub fn queryCode(c: Code) []const u8 {
    return switch (c) {
        .queue_does_not_exist => "AWS.SimpleQueueService.NonExistentQueue",
        .queue_name_exists => "QueueAlreadyExists",
        .queue_deleted_recently => "AWS.SimpleQueueService.QueueDeletedRecently",
        .unsupported_operation => "AWS.SimpleQueueService.UnsupportedOperation",
        .invalid_attribute_name => "InvalidAttributeName",
        .invalid_attribute_value => "InvalidAttributeValue",
        .missing_required_parameter => "MissingParameter",
        .invalid_parameter_value => "InvalidParameterValue",
        .receipt_handle_invalid => "ReceiptHandleIsInvalid",
        .invalid_id_format => "InvalidIdFormat",
        .message_not_inflight => "AWS.SimpleQueueService.MessageNotInflight",
        .purge_queue_in_progress => "AWS.SimpleQueueService.PurgeQueueInProgress",
        .empty_batch_request => "AWS.SimpleQueueService.EmptyBatchRequest",
        .too_many_entries_in_batch => "AWS.SimpleQueueService.TooManyEntriesInBatchRequest",
        .batch_entry_ids_not_distinct => "AWS.SimpleQueueService.BatchEntryIdsNotDistinct",
        .invalid_batch_entry_id => "AWS.SimpleQueueService.InvalidBatchEntryId",
        .batch_request_too_long => "AWS.SimpleQueueService.BatchRequestTooLong",
        .over_limit => "OverLimit",
        .internal_error => "InternalError",
        .unrecognized_action => "InvalidAction",
    };
}

pub fn defaultMessage(c: Code) []const u8 {
    return switch (c) {
        .queue_does_not_exist => "The specified queue does not exist.",
        .queue_name_exists => "A queue already exists with the same name and a different value for attribute(s).",
        .queue_deleted_recently => "You must wait 60 seconds after deleting a queue before you can create another with the same name.",
        .unsupported_operation => "Operation not supported.",
        .invalid_attribute_name => "The specified attribute does not exist.",
        .invalid_attribute_value => "Invalid value for an attribute.",
        .missing_required_parameter => "A required parameter is missing.",
        .invalid_parameter_value => "Invalid value for a parameter.",
        .receipt_handle_invalid => "The specified receipt handle is not valid.",
        .invalid_id_format => "The specified receipt handle is not valid for the current version.",
        .message_not_inflight => "The specified message is not in flight.",
        .purge_queue_in_progress => "Only one PurgeQueue operation on each queue is allowed every 60 seconds.",
        .empty_batch_request => "The batch request does not contain any entries.",
        .too_many_entries_in_batch => "The batch request contains more entries than permissible.",
        .batch_entry_ids_not_distinct => "Two or more batch entries in the request have the same Id.",
        .invalid_batch_entry_id => "A batch entry id can only contain alphanumeric characters, hyphens and underscores. It can be at most 80 letters long.",
        .batch_request_too_long => "Batch requests cannot be longer than 262144 bytes.",
        .over_limit => "The specified action violates a limit.",
        .internal_error => "An internal error occurred.",
        .unrecognized_action => "The action or operation requested is invalid.",
    };
}

pub const Error = struct {
    code: Code,
    message: []const u8 = "",

    pub fn messageOrDefault(self: Error) []const u8 {
        return if (self.message.len > 0) self.message else defaultMessage(self.code);
    }
};

const testing = std.testing;

test "jsonType exact strings" {
    try testing.expectEqualStrings("com.amazonaws.sqs#QueueDoesNotExist", jsonType(.queue_does_not_exist));
    try testing.expectEqualStrings("com.amazonaws.sqs#InvalidAction", jsonType(.unrecognized_action));
}

test "queryCode exact strings" {
    try testing.expectEqualStrings("AWS.SimpleQueueService.NonExistentQueue", queryCode(.queue_does_not_exist));
    try testing.expectEqualStrings("QueueAlreadyExists", queryCode(.queue_name_exists));
}

test "httpStatus mapping" {
    try testing.expectEqual(@as(u16, 400), httpStatus(.queue_does_not_exist));
    try testing.expectEqual(@as(u16, 404), httpStatus(.receipt_handle_invalid));
    try testing.expectEqual(@as(u16, 403), httpStatus(.purge_queue_in_progress));
    try testing.expectEqual(@as(u16, 403), httpStatus(.over_limit));
    try testing.expectEqual(@as(u16, 500), httpStatus(.internal_error));
}

test "every code has non-empty wire strings" {
    inline for (std.meta.fields(Code)) |f| {
        const c: Code = @enumFromInt(f.value);
        try testing.expect(jsonType(c).len > 0);
        try testing.expect(queryCode(c).len > 0);
        try testing.expect(defaultMessage(c).len > 0);
    }
}

test "messageOrDefault override" {
    const e: Error = .{ .code = .queue_does_not_exist, .message = "custom" };
    try testing.expectEqualStrings("custom", e.messageOrDefault());
    const d: Error = .{ .code = .queue_does_not_exist };
    try testing.expectEqualStrings("The specified queue does not exist.", d.messageOrDefault());
}
