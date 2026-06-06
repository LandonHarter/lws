const std = @import("std");
const id = @import("core").id;

pub const Handle = struct {
    queue_id: [16]u8,
    msg_seq: u64,
    lease_nonce: u64,
    visible_at_ms: i64,
};

const raw_len = 16 + 8 + 8 + 8;

pub const DecodeError = error{InvalidReceiptHandle};

fn pack(h: Handle) [raw_len]u8 {
    var buf: [raw_len]u8 = undefined;
    @memcpy(buf[0..16], &h.queue_id);
    std.mem.writeInt(u64, buf[16..24], h.msg_seq, .little);
    std.mem.writeInt(u64, buf[24..32], h.lease_nonce, .little);
    std.mem.writeInt(i64, buf[32..40], h.visible_at_ms, .little);
    return buf;
}

pub fn encode(gpa: std.mem.Allocator, h: Handle) ![]u8 {
    const raw = pack(h);
    const out = try gpa.alloc(u8, id.base64UrlEncodeLen(raw.len));
    _ = id.base64UrlEncode(out, &raw);
    return out;
}

pub fn decode(buf: []const u8) DecodeError!Handle {
    const decoded_len = id.base64UrlDecodeLen(buf) catch return DecodeError.InvalidReceiptHandle;
    if (decoded_len != raw_len) return DecodeError.InvalidReceiptHandle;
    var raw: [raw_len]u8 = undefined;
    _ = id.base64UrlDecode(&raw, buf) catch return DecodeError.InvalidReceiptHandle;
    var h: Handle = undefined;
    @memcpy(&h.queue_id, raw[0..16]);
    h.msg_seq = std.mem.readInt(u64, raw[16..24], .little);
    h.lease_nonce = std.mem.readInt(u64, raw[24..32], .little);
    h.visible_at_ms = std.mem.readInt(i64, raw[32..40], .little);
    return h;
}

const testing = std.testing;

test "encode/decode round-trip" {
    const h: Handle = .{
        .queue_id = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },
        .msg_seq = 0xdead_beef_1234,
        .lease_nonce = 0x9999_8888_7777,
        .visible_at_ms = 1_700_000_000_123,
    };
    const enc = try encode(testing.allocator, h);
    defer testing.allocator.free(enc);
    const got = try decode(enc);
    try testing.expectEqualSlices(u8, &h.queue_id, &got.queue_id);
    try testing.expectEqual(h.msg_seq, got.msg_seq);
    try testing.expectEqual(h.lease_nonce, got.lease_nonce);
    try testing.expectEqual(h.visible_at_ms, got.visible_at_ms);
}

test "garbage rejected" {
    try testing.expectError(DecodeError.InvalidReceiptHandle, decode("not!valid!base64!!"));
    try testing.expectError(DecodeError.InvalidReceiptHandle, decode("aGVsbG8"));
}
