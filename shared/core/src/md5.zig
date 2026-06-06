const std = @import("std");

pub const Md5 = std.crypto.hash.Md5;

pub fn hexLower(out: *[32]u8, bytes: []const u8) void {
    var raw: [16]u8 = undefined;
    Md5.hash(bytes, &raw, .{});
    const alphabet = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0xf];
    }
}

const testing = std.testing;

test "rfc 1864 vectors" {
    var out: [32]u8 = undefined;

    hexLower(&out, "");
    try testing.expectEqualStrings("d41d8cd98f00b204e9800998ecf8427e", &out);

    hexLower(&out, "abc");
    try testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", &out);

    hexLower(&out, "The quick brown fox jumps over the lazy dog");
    try testing.expectEqualStrings("9e107d9d372bb6826bd81d3542a419d6", &out);
}
