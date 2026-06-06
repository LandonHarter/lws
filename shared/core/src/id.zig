const std = @import("std");

const codec = std.base64.url_safe_no_pad;

pub fn uuidV4(rng: std.Random, out: *[36]u8) void {
    var bytes: [16]u8 = undefined;
    rng.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    const layout = [_]u8{ 4, 2, 2, 2, 6 };
    var bi: usize = 0;
    var oi: usize = 0;
    for (layout, 0..) |group_len, gi| {
        if (gi != 0) {
            out[oi] = '-';
            oi += 1;
        }
        var k: usize = 0;
        while (k < group_len) : (k += 1) {
            const b = bytes[bi];
            bi += 1;
            out[oi] = hex[b >> 4];
            out[oi + 1] = hex[b & 0x0f];
            oi += 2;
        }
    }
}

pub fn base64UrlEncodeLen(src_len: usize) usize {
    return codec.Encoder.calcSize(src_len);
}

pub fn base64UrlEncode(dst: []u8, src: []const u8) []const u8 {
    return codec.Encoder.encode(dst, src);
}

pub fn base64UrlDecodeLen(src: []const u8) !usize {
    return codec.Decoder.calcSizeForSlice(src);
}

pub fn base64UrlDecode(dst: []u8, src: []const u8) ![]u8 {
    const n = try codec.Decoder.calcSizeForSlice(src);
    try codec.Decoder.decode(dst[0..n], src);
    return dst[0..n];
}

const testing = std.testing;

test "uuidV4 format" {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rng = prng.random();
    var out: [36]u8 = undefined;
    uuidV4(rng, &out);
    try testing.expectEqual(@as(usize, 36), out.len);
    try testing.expectEqual(@as(u8, '-'), out[8]);
    try testing.expectEqual(@as(u8, '-'), out[13]);
    try testing.expectEqual(@as(u8, '-'), out[18]);
    try testing.expectEqual(@as(u8, '-'), out[23]);
    try testing.expectEqual(@as(u8, '4'), out[14]);
    const y = out[19];
    try testing.expect(y == '8' or y == '9' or y == 'a' or y == 'b');
    for (out, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(ok);
    }
}

test "uuidV4 differs across calls" {
    var prng = std.Random.DefaultPrng.init(1);
    const rng = prng.random();
    var a: [36]u8 = undefined;
    var b: [36]u8 = undefined;
    uuidV4(rng, &a);
    uuidV4(rng, &b);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "base64url round-trip" {
    const src = "hello\x00\xff world";
    var enc_buf: [64]u8 = undefined;
    const enc = base64UrlEncode(&enc_buf, src);
    var dec_buf: [64]u8 = undefined;
    const dec = try base64UrlDecode(&dec_buf, enc);
    try testing.expectEqualStrings(src, dec);
}
