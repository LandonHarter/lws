const std = @import("std");

pub fn parsePayload(arena: std.mem.Allocator, body: []const u8) !std.json.Value {
    if (body.len == 0) return std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    return std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
}

const Frame = struct {
    kind: enum { object, array },
    first: bool = true,
};

pub const Writer = struct {
    buf: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(Frame) = .empty,
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) Writer {
        return .{ .arena = arena };
    }

    fn raw(self: *Writer, s: []const u8) !void {
        try self.buf.appendSlice(self.arena, s);
    }

    fn top(self: *Writer) ?*Frame {
        if (self.stack.items.len == 0) return null;
        return &self.stack.items[self.stack.items.len - 1];
    }

    fn arraySep(self: *Writer) !void {
        if (self.top()) |f| {
            if (f.kind == .array) {
                if (!f.first) try self.raw(",");
                f.first = false;
            }
        }
    }

    pub fn beginObject(self: *Writer) !void {
        try self.arraySep();
        try self.raw("{");
        try self.stack.append(self.arena, .{ .kind = .object });
    }

    pub fn endObject(self: *Writer) !void {
        _ = self.stack.pop();
        try self.raw("}");
    }

    pub fn beginArray(self: *Writer) !void {
        try self.arraySep();
        try self.raw("[");
        try self.stack.append(self.arena, .{ .kind = .array });
    }

    pub fn endArray(self: *Writer) !void {
        _ = self.stack.pop();
        try self.raw("]");
    }

    pub fn writeKey(self: *Writer, key: []const u8) !void {
        if (self.top()) |f| {
            if (!f.first) try self.raw(",");
            f.first = false;
        }
        try self.writeJsonStr(key);
        try self.raw(":");
    }

    fn writeJsonStr(self: *Writer, s: []const u8) !void {
        try self.raw("\"");
        for (s) |c| {
            switch (c) {
                '"' => try self.raw("\\\""),
                '\\' => try self.raw("\\\\"),
                '\n' => try self.raw("\\n"),
                '\r' => try self.raw("\\r"),
                '\t' => try self.raw("\\t"),
                else => {
                    if (c < 0x20) {
                        var b: [8]u8 = undefined;
                        const hex = std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch unreachable;
                        try self.raw(hex);
                    } else {
                        try self.buf.append(self.arena, c);
                    }
                },
            }
        }
        try self.raw("\"");
    }

    pub fn writeString(self: *Writer, s: []const u8) !void {
        try self.arraySep();
        try self.writeJsonStr(s);
    }

    pub fn writeInt(self: *Writer, n: i64) !void {
        try self.arraySep();
        var b: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "{d}", .{n}) catch unreachable;
        try self.raw(s);
    }

    pub fn writeBool(self: *Writer, b: bool) !void {
        try self.arraySep();
        try self.raw(if (b) "true" else "false");
    }

    pub fn writeRaw(self: *Writer, raw_bytes: []const u8) !void {
        try self.arraySep();
        try self.raw(raw_bytes);
    }

    pub fn finish(self: *Writer) []const u8 {
        return self.buf.items;
    }
};

pub fn writeError(arena: std.mem.Allocator, code: []const u8, message: []const u8) ![]const u8 {
    var w = Writer.init(arena);
    try w.beginObject();
    try w.writeKey("__type");
    try w.writeString(code);
    try w.writeKey("message");
    try w.writeString(message);
    try w.endObject();
    return w.finish();
}

const testing = std.testing;

test "parsePayload empty body yields empty object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parsePayload(arena.allocator(), "");
    try testing.expect(v == .object);
    try testing.expectEqual(@as(usize, 0), v.object.count());
}

test "parsePayload reads object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parsePayload(arena.allocator(), "{\"a\":1}");
    try testing.expectEqual(@as(i64, 1), v.object.get("a").?.integer);
}

test "writeError exact bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try writeError(arena.allocator(), "com.amazonaws.sqs#X", "y");
    try testing.expectEqualStrings("{\"__type\":\"com.amazonaws.sqs#X\",\"message\":\"y\"}", s);
}

test "writer nested object and array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var w = Writer.init(arena.allocator());
    try w.beginObject();
    try w.writeKey("Urls");
    try w.beginArray();
    try w.writeString("a");
    try w.writeString("b");
    try w.endArray();
    try w.writeKey("n");
    try w.writeInt(5);
    try w.endObject();
    try testing.expectEqualStrings("{\"Urls\":[\"a\",\"b\"],\"n\":5}", w.finish());
}

test "writer escapes string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var w = Writer.init(arena.allocator());
    try w.writeString("a\"b\\c\n");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", w.finish());
}
