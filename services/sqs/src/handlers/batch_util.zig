const std = @import("std");
const errors = @import("../errors.zig");
const json_proto = @import("../wire/json_proto.zig");
const query_proto = @import("../wire/query_proto.zig");

pub const BatchAction = enum { send, delete, change_visibility };

pub const ResultSuccess = struct {
    id: []const u8,
    message_id: ?[36]u8 = null,
    md5_of_body: ?[32]u8 = null,
    md5_of_attrs: ?[32]u8 = null,
    sequence_number: ?u64 = null,
};

pub const ResultFailure = struct {
    id: []const u8,
    code: []const u8,
    message: []const u8,
    sender_fault: bool = true,
};

pub const BatchResultEntry = union(enum) {
    success: ResultSuccess,
    failure: ResultFailure,
};

pub const EnvelopeError = error{
    EmptyBatchRequest,
    TooManyEntriesInBatchRequest,
    BatchEntryIdsNotDistinct,
    InvalidBatchEntryId,
};

pub fn envelopeCode(e: EnvelopeError) errors.Code {
    return switch (e) {
        error.EmptyBatchRequest => .empty_batch_request,
        error.TooManyEntriesInBatchRequest => .too_many_entries_in_batch,
        error.BatchEntryIdsNotDistinct => .batch_entry_ids_not_distinct,
        error.InvalidBatchEntryId => .invalid_batch_entry_id,
    };
}

// Envelope rules shared by all batch APIs: 1-10 entries, each Id 1-80 chars of
// [a-zA-Z0-9_-], unique within the request. n <= 10 so the dup check is O(n^2)
// with no allocation.
pub fn validateIds(ids: []const []const u8) EnvelopeError!void {
    if (ids.len == 0) return error.EmptyBatchRequest;
    if (ids.len > 10) return error.TooManyEntriesInBatchRequest;
    for (ids, 0..) |idv, i| {
        if (idv.len < 1 or idv.len > 80) return error.InvalidBatchEntryId;
        for (idv) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidBatchEntryId;
        }
        for (ids[0..i]) |prev| {
            if (std.mem.eql(u8, prev, idv)) return error.BatchEntryIdsNotDistinct;
        }
    }
}

// Builds "{prefix}.{n}.{field}" for query-protocol entry indexing.
pub fn entryKey(buf: []u8, prefix: []const u8, n: usize, field: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.{d}.{s}", .{ prefix, n, field });
}

fn rootName(action: BatchAction) []const u8 {
    return switch (action) {
        .send => "SendMessageBatch",
        .delete => "DeleteMessageBatch",
        .change_visibility => "ChangeMessageVisibilityBatch",
    };
}

pub fn writeJson(arena: std.mem.Allocator, action: BatchAction, results: []const BatchResultEntry) ![]const u8 {
    var w = json_proto.Writer.init(arena);
    try w.beginObject();
    try w.writeKey("Successful");
    try w.beginArray();
    for (results) |r| switch (r) {
        .success => |s| try writeSuccessJson(&w, action, s),
        .failure => {},
    };
    try w.endArray();
    try w.writeKey("Failed");
    try w.beginArray();
    for (results) |r| switch (r) {
        .failure => |f| try writeFailureJson(&w, f),
        .success => {},
    };
    try w.endArray();
    try w.endObject();
    return w.finish();
}

fn writeSuccessJson(w: *json_proto.Writer, action: BatchAction, s: ResultSuccess) !void {
    try w.beginObject();
    try w.writeKey("Id");
    try w.writeString(s.id);
    if (action == .send) {
        if (s.message_id) |m| {
            try w.writeKey("MessageId");
            try w.writeString(&m);
        }
        if (s.md5_of_body) |m| {
            try w.writeKey("MD5OfMessageBody");
            try w.writeString(&m);
        }
        if (s.md5_of_attrs) |m| {
            try w.writeKey("MD5OfMessageAttributes");
            try w.writeString(&m);
        }
        if (s.sequence_number) |sn| {
            var b: [24]u8 = undefined;
            try w.writeKey("SequenceNumber");
            try w.writeString(std.fmt.bufPrint(&b, "{d}", .{sn}) catch unreachable);
        }
    }
    try w.endObject();
}

fn writeFailureJson(w: *json_proto.Writer, f: ResultFailure) !void {
    try w.beginObject();
    try w.writeKey("Id");
    try w.writeString(f.id);
    try w.writeKey("SenderFault");
    try w.writeBool(f.sender_fault);
    try w.writeKey("Code");
    try w.writeString(f.code);
    try w.writeKey("Message");
    try w.writeString(f.message);
    try w.endObject();
}

pub fn writeXml(arena: std.mem.Allocator, action: BatchAction, results: []const BatchResultEntry, request_id: []const u8) ![]const u8 {
    const root = rootName(action);
    const resp_tag = try std.fmt.allocPrint(arena, "{s}Response", .{root});
    const result_tag = try std.fmt.allocPrint(arena, "{s}Result", .{root});
    const entry_tag = try std.fmt.allocPrint(arena, "{s}ResultEntry", .{root});

    var x = query_proto.XmlWriter.init(arena);
    try x.declaration();
    try x.open(resp_tag);
    try x.open(result_tag);
    for (results) |r| switch (r) {
        .success => |s| {
            try x.open(entry_tag);
            try x.element("Id", s.id);
            if (action == .send) {
                if (s.message_id) |m| try x.element("MessageId", &m);
                if (s.md5_of_body) |m| try x.element("MD5OfMessageBody", &m);
                if (s.md5_of_attrs) |m| try x.element("MD5OfMessageAttributes", &m);
                if (s.sequence_number) |sn| {
                    var b: [24]u8 = undefined;
                    try x.element("SequenceNumber", std.fmt.bufPrint(&b, "{d}", .{sn}) catch unreachable);
                }
            }
            try x.close(entry_tag);
        },
        .failure => |f| {
            try x.open("BatchResultErrorEntry");
            try x.element("Id", f.id);
            try x.element("Code", f.code);
            try x.element("Message", f.message);
            try x.element("SenderFault", if (f.sender_fault) "true" else "false");
            try x.close("BatchResultErrorEntry");
        },
    };
    try x.close(result_tag);
    try x.open("ResponseMetadata");
    try x.element("RequestId", request_id);
    try x.close("ResponseMetadata");
    try x.close(resp_tag);
    return x.finish();
}

const testing = std.testing;

test "validateIds accepts 1-10 unique ids" {
    try validateIds(&.{ "a", "b", "c" });
}

test "validateIds empty -> EmptyBatchRequest" {
    try testing.expectError(error.EmptyBatchRequest, validateIds(&.{}));
}

test "validateIds 11 entries -> TooManyEntriesInBatchRequest" {
    const ids = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11" };
    try testing.expectError(error.TooManyEntriesInBatchRequest, validateIds(&ids));
}

test "validateIds duplicate -> BatchEntryIdsNotDistinct" {
    try testing.expectError(error.BatchEntryIdsNotDistinct, validateIds(&.{ "a", "b", "a" }));
}

test "validateIds bad charset -> InvalidBatchEntryId" {
    try testing.expectError(error.InvalidBatchEntryId, validateIds(&.{"a!b"}));
}

test "validateIds too long -> InvalidBatchEntryId" {
    const long = "a" ** 81;
    try testing.expectError(error.InvalidBatchEntryId, validateIds(&.{long}));
}

test "writeJson send mixed success and failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const results = [_]BatchResultEntry{
        .{ .success = .{ .id = "a", .message_id = "00000000-0000-4000-8000-000000000000".*, .md5_of_body = "0123456789abcdef0123456789abcdef".* } },
        .{ .failure = .{ .id = "b", .code = "InvalidParameterValue", .message = "bad" } },
    };
    const out = try writeJson(arena.allocator(), .send, &results);
    try testing.expectEqualStrings(
        "{\"Successful\":[{\"Id\":\"a\",\"MessageId\":\"00000000-0000-4000-8000-000000000000\",\"MD5OfMessageBody\":\"0123456789abcdef0123456789abcdef\"}],\"Failed\":[{\"Id\":\"b\",\"SenderFault\":true,\"Code\":\"InvalidParameterValue\",\"Message\":\"bad\"}]}",
        out,
    );
}

test "writeJson delete success omits send-only fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const results = [_]BatchResultEntry{
        .{ .success = .{ .id = "a" } },
    };
    const out = try writeJson(arena.allocator(), .delete, &results);
    try testing.expectEqualStrings("{\"Successful\":[{\"Id\":\"a\"}],\"Failed\":[]}", out);
}

test "writeXml change_visibility shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const results = [_]BatchResultEntry{
        .{ .success = .{ .id = "a" } },
        .{ .failure = .{ .id = "b", .code = "AWS.SimpleQueueService.MessageNotInflight", .message = "nope" } },
    };
    const out = try writeXml(arena.allocator(), .change_visibility, &results, "rid-1");
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ChangeMessageVisibilityBatchResponse><ChangeMessageVisibilityBatchResult><ChangeMessageVisibilityBatchResultEntry><Id>a</Id></ChangeMessageVisibilityBatchResultEntry><BatchResultErrorEntry><Id>b</Id><Code>AWS.SimpleQueueService.MessageNotInflight</Code><Message>nope</Message><SenderFault>true</SenderFault></BatchResultErrorEntry></ChangeMessageVisibilityBatchResult><ResponseMetadata><RequestId>rid-1</RequestId></ResponseMetadata></ChangeMessageVisibilityBatchResponse>",
        out,
    );
}
