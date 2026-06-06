const std = @import("std");
const md5 = @import("core").md5;

pub const MessageAttribute = struct {
    name: []const u8,
    data_type: []const u8,
    string_value: ?[]const u8 = null,
    binary_value: ?[]const u8 = null,
};

pub const Message = struct {
    id: [36]u8,
    seq: u64,
    body: []const u8,
    md5_of_body: [32]u8,
    md5_of_attrs: ?[32]u8,
    attributes: []MessageAttribute,
    sent_at_ms: i64,
    delay_until_ms: i64,
    receive_count: u32,
    first_received_at_ms: ?i64,

    // FIFO fields (null for standard queues; populated by Plan 05):
    group_id: ?[]const u8 = null,
    dedup_id: ?[]const u8 = null,

    trace_header: ?[]const u8 = null,

    // Frees all owned slices and the struct itself.
    pub fn destroy(self: *Message, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
        for (self.attributes) |a| {
            gpa.free(a.name);
            gpa.free(a.data_type);
            if (a.string_value) |v| gpa.free(v);
            if (a.binary_value) |v| gpa.free(v);
        }
        gpa.free(self.attributes);
        if (self.group_id) |v| gpa.free(v);
        if (self.dedup_id) |v| gpa.free(v);
        if (self.trace_header) |v| gpa.free(v);
        gpa.destroy(self);
    }
};

pub const Lease = struct {
    msg_seq: u64,
    nonce: u64,
    visible_at_ms: i64,
};

pub fn computeBodyMd5(out: *[32]u8, body: []const u8) void {
    md5.hexLower(out, body);
}

fn lessByName(_: void, a: MessageAttribute, b: MessageAttribute) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

// MD5 of message attributes per AWS wire format: attrs sorted by name, then
// for each: BE-u32 nameLen, name, BE-u32 dataTypeLen, dataType, transport-type
// byte (1=string/number, 2=binary), BE-u32 valueLen, value.
pub fn computeAttrsMd5(gpa: std.mem.Allocator, out: *[32]u8, attrs: []const MessageAttribute) !void {
    const sorted = try gpa.dupe(MessageAttribute, attrs);
    defer gpa.free(sorted);
    std.mem.sort(MessageAttribute, sorted, {}, lessByName);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    for (sorted) |a| {
        try appendLenPrefixed(gpa, &buf, a.name);
        try appendLenPrefixed(gpa, &buf, a.data_type);
        const is_binary = std.mem.startsWith(u8, a.data_type, "Binary");
        if (is_binary) {
            try buf.append(gpa, 2);
            try appendLenPrefixed(gpa, &buf, a.binary_value orelse "");
        } else {
            try buf.append(gpa, 1);
            try appendLenPrefixed(gpa, &buf, a.string_value orelse "");
        }
    }

    md5.hexLower(out, buf.items);
}

fn appendLenPrefixed(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), bytes: []const u8) !void {
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(bytes.len), .big);
    try buf.appendSlice(gpa, &len_be);
    try buf.appendSlice(gpa, bytes);
}

const testing = std.testing;

test "computeBodyMd5 rfc vectors" {
    var out: [32]u8 = undefined;
    computeBodyMd5(&out, "abc");
    try testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", &out);
}

test "computeAttrsMd5 single string attr" {
    // boto3 reference: single attr {Name: "k", Value: "v", DataType: "String"}
    // -> md5 of: 0000000_1 'k' 0000000_6 'String' 01 0000000_1 'v'
    var out: [32]u8 = undefined;
    const attrs = [_]MessageAttribute{
        .{ .name = "k", .data_type = "String", .string_value = "v" },
    };
    try computeAttrsMd5(testing.allocator, &out, &attrs);

    // recompute the expected digest from the exact wire bytes
    var expected_buf: [64]u8 = undefined;
    var i: usize = 0;
    // nameLen=1, name
    expected_buf[i] = 0;
    expected_buf[i + 1] = 0;
    expected_buf[i + 2] = 0;
    expected_buf[i + 3] = 1;
    i += 4;
    expected_buf[i] = 'k';
    i += 1;
    // dataTypeLen=6, "String"
    std.mem.writeInt(u32, expected_buf[i..][0..4], 6, .big);
    i += 4;
    @memcpy(expected_buf[i .. i + 6], "String");
    i += 6;
    // transport=1
    expected_buf[i] = 1;
    i += 1;
    // valueLen=1, "v"
    std.mem.writeInt(u32, expected_buf[i..][0..4], 1, .big);
    i += 4;
    expected_buf[i] = 'v';
    i += 1;
    var expected: [32]u8 = undefined;
    md5.hexLower(&expected, expected_buf[0..i]);
    try testing.expectEqualStrings(&expected, &out);
}

test "computeAttrsMd5 order independent of input order" {
    var a_out: [32]u8 = undefined;
    var b_out: [32]u8 = undefined;
    const a = [_]MessageAttribute{
        .{ .name = "a", .data_type = "String", .string_value = "1" },
        .{ .name = "b", .data_type = "Number", .string_value = "2" },
    };
    const b = [_]MessageAttribute{
        .{ .name = "b", .data_type = "Number", .string_value = "2" },
        .{ .name = "a", .data_type = "String", .string_value = "1" },
    };
    try computeAttrsMd5(testing.allocator, &a_out, &a);
    try computeAttrsMd5(testing.allocator, &b_out, &b);
    try testing.expectEqualStrings(&a_out, &b_out);
}

test "computeAttrsMd5 binary transport differs" {
    var s_out: [32]u8 = undefined;
    var bin_out: [32]u8 = undefined;
    const s = [_]MessageAttribute{.{ .name = "k", .data_type = "String", .string_value = "x" }};
    const bin = [_]MessageAttribute{.{ .name = "k", .data_type = "Binary", .binary_value = "x" }};
    try computeAttrsMd5(testing.allocator, &s_out, &s);
    try computeAttrsMd5(testing.allocator, &bin_out, &bin);
    try testing.expect(!std.mem.eql(u8, &s_out, &bin_out));
}
