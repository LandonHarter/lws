const std = @import("std");

pub const s3_ns = "http://s3.amazonaws.com/doc/2006-03-01/";

pub const Writer = struct {
    buf: std.ArrayList(u8) = .empty,
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) Writer {
        return .{ .arena = arena };
    }

    fn raw(self: *Writer, s: []const u8) !void {
        try self.buf.appendSlice(self.arena, s);
    }

    pub fn declaration(self: *Writer) !void {
        try self.raw("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    }

    pub fn open(self: *Writer, tag: []const u8) !void {
        try self.raw("<");
        try self.raw(tag);
        try self.raw(">");
    }

    pub fn openNs(self: *Writer, tag: []const u8, xmlns: []const u8) !void {
        try self.raw("<");
        try self.raw(tag);
        try self.raw(" xmlns=\"");
        try self.raw(xmlns);
        try self.raw("\">");
    }

    pub fn close(self: *Writer, tag: []const u8) !void {
        try self.raw("</");
        try self.raw(tag);
        try self.raw(">");
    }

    pub fn text(self: *Writer, body: []const u8) !void {
        for (body) |c| {
            switch (c) {
                '<' => try self.raw("&lt;"),
                '>' => try self.raw("&gt;"),
                '&' => try self.raw("&amp;"),
                '"' => try self.raw("&quot;"),
                '\'' => try self.raw("&apos;"),
                else => try self.buf.append(self.arena, c),
            }
        }
    }

    pub fn element(self: *Writer, tag: []const u8, body: []const u8) !void {
        try self.open(tag);
        try self.text(body);
        try self.close(tag);
    }

    pub fn elementInt(self: *Writer, tag: []const u8, n: i64) !void {
        try self.open(tag);
        var b: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "{d}", .{n}) catch unreachable;
        try self.raw(s);
        try self.close(tag);
    }

    pub fn elementBool(self: *Writer, tag: []const u8, b: bool) !void {
        try self.open(tag);
        try self.raw(if (b) "true" else "false");
        try self.close(tag);
    }

    pub fn finish(self: *Writer) []const u8 {
        return self.buf.items;
    }
};

const testing = std.testing;

test "declaration and escaping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var x = Writer.init(arena.allocator());
    try x.declaration();
    try x.element("a", "<&\">");
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><a>&lt;&amp;&quot;&gt;</a>",
        x.finish(),
    );
}

test "openNs emits namespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var x = Writer.init(arena.allocator());
    try x.openNs("ListAllMyBucketsResult", s3_ns);
    try x.close("ListAllMyBucketsResult");
    try testing.expectEqualStrings(
        "<ListAllMyBucketsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"></ListAllMyBucketsResult>",
        x.finish(),
    );
}

test "elementInt and elementBool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var x = Writer.init(arena.allocator());
    try x.elementInt("Size", 4096);
    try x.elementBool("IsTruncated", true);
    try testing.expectEqualStrings("<Size>4096</Size><IsTruncated>true</IsTruncated>", x.finish());
}
