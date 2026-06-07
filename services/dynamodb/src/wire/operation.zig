const std = @import("std");

pub const Operation = enum {
    // Table ops
    create_table,
    delete_table,
    describe_table,
    list_tables,
    update_table,
    update_time_to_live,
    describe_time_to_live,
    list_tags_of_resource,
    tag_resource,
    untag_resource,

    // Item ops
    put_item,
    get_item,
    update_item,
    delete_item,

    // Multi-item
    batch_get_item,
    batch_write_item,
    query,
    scan,

    // Transactions
    transact_get_items,
    transact_write_items,

    // Unrecognized target.
    unknown,
};

const Entry = struct { name: []const u8, op: Operation };

const table = [_]Entry{
    .{ .name = "CreateTable", .op = .create_table },
    .{ .name = "DeleteTable", .op = .delete_table },
    .{ .name = "DescribeTable", .op = .describe_table },
    .{ .name = "ListTables", .op = .list_tables },
    .{ .name = "UpdateTable", .op = .update_table },
    .{ .name = "UpdateTimeToLive", .op = .update_time_to_live },
    .{ .name = "DescribeTimeToLive", .op = .describe_time_to_live },
    .{ .name = "ListTagsOfResource", .op = .list_tags_of_resource },
    .{ .name = "TagResource", .op = .tag_resource },
    .{ .name = "UntagResource", .op = .untag_resource },
    .{ .name = "PutItem", .op = .put_item },
    .{ .name = "GetItem", .op = .get_item },
    .{ .name = "UpdateItem", .op = .update_item },
    .{ .name = "DeleteItem", .op = .delete_item },
    .{ .name = "BatchGetItem", .op = .batch_get_item },
    .{ .name = "BatchWriteItem", .op = .batch_write_item },
    .{ .name = "Query", .op = .query },
    .{ .name = "Scan", .op = .scan },
    .{ .name = "TransactGetItems", .op = .transact_get_items },
    .{ .name = "TransactWriteItems", .op = .transact_write_items },
};

// "DynamoDB_20120810.PutItem" -> .put_item. The action is whatever follows the
// final '.'; any unrecognized action (or missing dot) yields .unknown.
pub fn fromTarget(t: []const u8) Operation {
    const dot = std.mem.lastIndexOfScalar(u8, t, '.') orelse return .unknown;
    const action = t[dot + 1 ..];
    for (table) |e| if (std.mem.eql(u8, e.name, action)) return e.op;
    return .unknown;
}

const testing = std.testing;

test "fromTarget resolves every action name" {
    for (table) |e| {
        var buf: [128]u8 = undefined;
        const target = std.fmt.bufPrint(&buf, "DynamoDB_20120810.{s}", .{e.name}) catch unreachable;
        try testing.expectEqual(e.op, fromTarget(target));
    }
}

test "fromTarget handles unknown and malformed" {
    try testing.expectEqual(Operation.unknown, fromTarget("DynamoDB_20120810.UnknownThing"));
    try testing.expectEqual(Operation.unknown, fromTarget("NoDotHere"));
    try testing.expectEqual(Operation.unknown, fromTarget(""));
    try testing.expectEqual(Operation.put_item, fromTarget("DynamoDB_20111205.PutItem"));
}
