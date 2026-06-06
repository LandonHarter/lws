const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

pub const Error = error{ BadStatus, MalformedResponse };

// Minimal HTTP/1.1 GET against a loopback service. Returns the response body
// (owned by `allocator`). Sends Connection: close so the body is read to EOF.
pub fn get(allocator: std.mem.Allocator, io: Io, host: []const u8, port: u16, path: []const u8) ![]u8 {
    const addr = try net.IpAddress.parse(host, port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [1024]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    const w = &sw.interface;
    try w.print(
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: application/json\r\nConnection: close\r\n\r\n",
        .{ path, host, port },
    );
    try w.flush();

    var rbuf: [4096]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;
    const raw = try r.allocRemaining(allocator, .limited(1 << 20));
    defer allocator.free(raw);

    const line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return error.MalformedResponse;
    var parts = std.mem.tokenizeScalar(u8, raw[0..line_end], ' ');
    _ = parts.next() orelse return error.MalformedResponse;
    const code_str = parts.next() orelse return error.MalformedResponse;
    const code = std.fmt.parseInt(u16, code_str, 10) catch return error.MalformedResponse;
    if (code != 200) return error.BadStatus;

    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.MalformedResponse;
    return allocator.dupe(u8, raw[sep + 4 ..]);
}
