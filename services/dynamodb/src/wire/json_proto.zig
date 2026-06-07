const std = @import("std");
const types = @import("../types.zig");
const AttributeValue = types.AttributeValue;
const Item = types.Item;

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

// ---- AttributeValue marshalling (DynamoDB JSON 1.0 discriminator form) ----

pub const AttrError = error{
    InvalidAttributeValue,
    InvalidNumber,
    NumberOutOfRange,
    DuplicateSetValue,
    InvalidBinary,
};

fn base64Encode(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(src.len));
    return enc.encode(out, src);
}

fn base64Decode(a: std.mem.Allocator, src: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(src) catch return error.InvalidBinary;
    const out = try a.alloc(u8, n);
    dec.decode(out, src) catch return error.InvalidBinary;
    return out;
}

// DynamoDB numbers: <=38 significant digits, magnitude within ~1e126.
fn validateNumber(raw: []const u8) AttrError!void {
    var sfa = std.heap.stackFallback(128, std.heap.page_allocator);
    const a = sfa.get();
    const canon = types.canonicalizeNumber(a, raw) catch return error.InvalidNumber;
    defer a.free(canon);
    var digits: usize = 0;
    for (canon) |c| {
        if (c >= '0' and c <= '9') digits += 1;
    }
    if (digits > 38) return error.NumberOutOfRange;
}

pub fn writeAttributeValue(w: *Writer, v: AttributeValue) !void {
    try w.beginObject();
    switch (v) {
        .S => |s| {
            try w.writeKey("S");
            try w.writeString(s);
        },
        .N => |s| {
            try w.writeKey("N");
            try w.writeString(s);
        },
        .B => |b| {
            try w.writeKey("B");
            try w.writeString(try base64Encode(w.arena, b));
        },
        .BOOL => |b| {
            try w.writeKey("BOOL");
            try w.writeBool(b);
        },
        .NULL => {
            try w.writeKey("NULL");
            try w.writeBool(true);
        },
        .L => |list| {
            try w.writeKey("L");
            try w.beginArray();
            for (list) |e| try writeAttributeValue(w, e);
            try w.endArray();
        },
        .M => |m| {
            try w.writeKey("M");
            try w.beginObject();
            var it = m.iterator();
            while (it.next()) |e| {
                try w.writeKey(e.key_ptr.*);
                try writeAttributeValue(w, e.value_ptr.*);
            }
            try w.endObject();
        },
        .SS => |set| {
            try w.writeKey("SS");
            try w.beginArray();
            for (set) |s| try w.writeString(s);
            try w.endArray();
        },
        .NS => |set| {
            try w.writeKey("NS");
            try w.beginArray();
            for (set) |s| try w.writeString(s);
            try w.endArray();
        },
        .BS => |set| {
            try w.writeKey("BS");
            try w.beginArray();
            for (set) |b| try w.writeString(try base64Encode(w.arena, b));
            try w.endArray();
        },
    }
    try w.endObject();
}

pub fn parseAttributeValue(arena: std.mem.Allocator, v: std.json.Value) !AttributeValue {
    if (v != .object) return error.InvalidAttributeValue;
    const obj = v.object;
    if (obj.count() != 1) return error.InvalidAttributeValue;
    var it = obj.iterator();
    const e = it.next().?;
    const tag = e.key_ptr.*;
    const val = e.value_ptr.*;

    if (std.mem.eql(u8, tag, "S")) {
        if (val != .string) return error.InvalidAttributeValue;
        return .{ .S = try arena.dupe(u8, val.string) };
    } else if (std.mem.eql(u8, tag, "N")) {
        if (val != .string) return error.InvalidAttributeValue;
        try validateNumber(val.string);
        return .{ .N = try arena.dupe(u8, val.string) };
    } else if (std.mem.eql(u8, tag, "B")) {
        if (val != .string) return error.InvalidAttributeValue;
        return .{ .B = try base64Decode(arena, val.string) };
    } else if (std.mem.eql(u8, tag, "BOOL")) {
        if (val != .bool) return error.InvalidAttributeValue;
        return .{ .BOOL = val.bool };
    } else if (std.mem.eql(u8, tag, "NULL")) {
        // NULL:true valid, NULL:false invalid.
        if (val != .bool or !val.bool) return error.InvalidAttributeValue;
        return .NULL;
    } else if (std.mem.eql(u8, tag, "L")) {
        if (val != .array) return error.InvalidAttributeValue;
        const items = val.array.items;
        const list = try arena.alloc(AttributeValue, items.len);
        for (items, 0..) |e2, i| list[i] = try parseAttributeValue(arena, e2);
        return .{ .L = list };
    } else if (std.mem.eql(u8, tag, "M")) {
        if (val != .object) return error.InvalidAttributeValue;
        var m: std.StringArrayHashMapUnmanaged(AttributeValue) = .empty;
        var mit = val.object.iterator();
        while (mit.next()) |me| {
            try m.put(arena, try arena.dupe(u8, me.key_ptr.*), try parseAttributeValue(arena, me.value_ptr.*));
        }
        return .{ .M = m };
    } else if (std.mem.eql(u8, tag, "SS")) {
        if (val != .array) return error.InvalidAttributeValue;
        const out = try arena.alloc([]const u8, val.array.items.len);
        for (val.array.items, 0..) |e2, i| {
            if (e2 != .string) return error.InvalidAttributeValue;
            out[i] = try arena.dupe(u8, e2.string);
        }
        try rejectDuplicateBytes(out);
        return .{ .SS = out };
    } else if (std.mem.eql(u8, tag, "NS")) {
        if (val != .array) return error.InvalidAttributeValue;
        const out = try arena.alloc([]const u8, val.array.items.len);
        for (val.array.items, 0..) |e2, i| {
            if (e2 != .string) return error.InvalidAttributeValue;
            try validateNumber(e2.string);
            out[i] = try arena.dupe(u8, e2.string);
        }
        try rejectDuplicateNumbers(out);
        return .{ .NS = out };
    } else if (std.mem.eql(u8, tag, "BS")) {
        if (val != .array) return error.InvalidAttributeValue;
        const out = try arena.alloc([]const u8, val.array.items.len);
        for (val.array.items, 0..) |e2, i| {
            if (e2 != .string) return error.InvalidAttributeValue;
            out[i] = try base64Decode(arena, e2.string);
        }
        try rejectDuplicateBytes(out);
        return .{ .BS = out };
    }
    return error.InvalidAttributeValue;
}

fn rejectDuplicateBytes(set: []const []const u8) AttrError!void {
    for (set, 0..) |x, i| {
        for (set[i + 1 ..]) |y| if (std.mem.eql(u8, x, y)) return error.DuplicateSetValue;
    }
}

fn rejectDuplicateNumbers(set: []const []const u8) AttrError!void {
    for (set, 0..) |x, i| {
        for (set[i + 1 ..]) |y| if (types.compareNumber(x, y) == .eq) return error.DuplicateSetValue;
    }
}

pub fn writeItem(w: *Writer, item: Item) !void {
    try w.beginObject();
    var it = item.attrs.iterator();
    while (it.next()) |e| {
        try w.writeKey(e.key_ptr.*);
        try writeAttributeValue(w, e.value_ptr.*);
    }
    try w.endObject();
}

pub fn parseItem(arena: std.mem.Allocator, v: std.json.Value) !Item {
    if (v != .object) return error.InvalidAttributeValue;
    var item: Item = .{};
    var it = v.object.iterator();
    while (it.next()) |e| {
        try item.attrs.put(arena, try arena.dupe(u8, e.key_ptr.*), try parseAttributeValue(arena, e.value_ptr.*));
    }
    return item;
}

const testing = std.testing;

test "parsePayload empty body yields empty object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parsePayload(arena.allocator(), "");
    try testing.expect(v == .object);
    try testing.expectEqual(@as(usize, 0), v.object.count());
}

fn roundTrip(arena: std.mem.Allocator, json: []const u8) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    const av = try parseAttributeValue(arena, v);
    var w = Writer.init(arena);
    try writeAttributeValue(&w, av);
    return w.finish();
}

test "attribute round-trip every variant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{
        "{\"S\":\"x\"}",
        "{\"S\":\"\"}", // empty string allowed
        "{\"N\":\"7\"}",
        "{\"BOOL\":true}",
        "{\"NULL\":true}",
        "{\"L\":[{\"S\":\"a\"},{\"N\":\"1\"}]}",
        "{\"M\":{\"k\":{\"S\":\"v\"}}}",
        "{\"SS\":[\"a\",\"b\"]}",
        "{\"NS\":[\"1\",\"2\"]}",
    };
    for (cases) |c| {
        const out = try roundTrip(a, c);
        try testing.expectEqualStrings(c, out);
    }
}

test "binary round-trips through base64" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"B\":\"aGk=\"}", .{});
    const av = try parseAttributeValue(a, v);
    try testing.expectEqualStrings("hi", av.B);
    var w = Writer.init(a);
    try writeAttributeValue(&w, av);
    try testing.expectEqualStrings("{\"B\":\"aGk=\"}", w.finish());
}

test "NULL false rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"NULL\":false}", .{});
    try testing.expectError(error.InvalidAttributeValue, parseAttributeValue(a, v));
}

test "duplicate set value rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"SS\":[\"a\",\"a\"]}", .{});
    try testing.expectError(error.DuplicateSetValue, parseAttributeValue(a, v));
    const v2 = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"NS\":[\"1\",\"1.0\"]}", .{});
    try testing.expectError(error.DuplicateSetValue, parseAttributeValue(a, v2));
}

test "number out of range rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = "{\"N\":\"123456789012345678901234567890123456789\"}"; // 39 digits
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, big, .{});
    try testing.expectError(error.NumberOutOfRange, parseAttributeValue(a, v));
}

test "item round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = "{\"id\":{\"S\":\"x\"},\"count\":{\"N\":\"7\"}}";
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const item = try parseItem(a, v);
    var w = Writer.init(a);
    try writeItem(&w, item);
    try testing.expectEqualStrings(json, w.finish());
}

test "non-object attribute rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "\"x\"", .{});
    try testing.expectError(error.InvalidAttributeValue, parseAttributeValue(a, v));
}
