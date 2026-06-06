const std = @import("std");

pub const Pair = struct { key: []const u8, value: []const u8 };

pub const PairIter = struct {
    rest: []const u8,

    pub fn next(self: *PairIter) ?Pair {
        while (self.rest.len > 0) {
            var seg = self.rest;
            if (std.mem.indexOfScalar(u8, self.rest, '&')) |amp| {
                seg = self.rest[0..amp];
                self.rest = self.rest[amp + 1 ..];
            } else {
                self.rest = self.rest[self.rest.len..];
            }
            if (seg.len == 0) continue;
            if (std.mem.indexOfScalar(u8, seg, '=')) |eq| {
                return .{ .key = seg[0..eq], .value = seg[eq + 1 ..] };
            }
            return .{ .key = seg, .value = "" };
        }
        return null;
    }
};

pub fn pairs(body: []const u8) PairIter {
    return .{ .rest = body };
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn percentDecode(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '+') {
            try out.append(arena, ' ');
            i += 1;
        } else if (c == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                try out.append(arena, (hi.? << 4) | lo.?);
                i += 3;
            } else {
                try out.append(arena, c);
                i += 1;
            }
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return out.items;
}

pub fn extractAction(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    var it = pairs(body);
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key, "Action")) return percentDecode(arena, kv.value);
    }
    return error.MissingAction;
}

pub fn getScalar(body: []const u8, arena: std.mem.Allocator, name: []const u8) !?[]const u8 {
    var it = pairs(body);
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key, name)) return try percentDecode(arena, kv.value);
    }
    return null;
}

// prefix contains "{i}" placeholder, e.g. "Attribute.{i}.Name".
pub fn getIndexedList(body: []const u8, arena: std.mem.Allocator, prefix: []const u8) ![]const []const u8 {
    const ph = std.mem.indexOf(u8, prefix, "{i}") orelse return error.InvalidPrefix;
    const head = prefix[0..ph];
    const tail = prefix[ph + 3 ..];

    var out: std.ArrayList([]const u8) = .empty;
    var idx: usize = 1;
    while (true) : (idx += 1) {
        var kb: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "{s}{d}{s}", .{ head, idx, tail }) catch return error.InvalidPrefix;
        const v = try getScalar(body, arena, key);
        if (v == null) break;
        try out.append(arena, v.?);
    }
    return out.items;
}

// prefix like "Attribute"; reads "{prefix}.{i}.Name" / "{prefix}.{i}.Value".
pub fn getIndexedMap(body: []const u8, arena: std.mem.Allocator, prefix: []const u8) !std.StringArrayHashMapUnmanaged([]const u8) {
    var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var idx: usize = 1;
    while (true) : (idx += 1) {
        var nb: [256]u8 = undefined;
        var vb: [256]u8 = undefined;
        const name_key = std.fmt.bufPrint(&nb, "{s}.{d}.Name", .{ prefix, idx }) catch return error.InvalidPrefix;
        const value_key = std.fmt.bufPrint(&vb, "{s}.{d}.Value", .{ prefix, idx }) catch return error.InvalidPrefix;
        const name = try getScalar(body, arena, name_key);
        if (name == null) break;
        const value = (try getScalar(body, arena, value_key)) orelse "";
        try map.put(arena, name.?, value);
    }
    return map;
}

pub const XmlWriter = struct {
    buf: std.ArrayList(u8) = .empty,
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) XmlWriter {
        return .{ .arena = arena };
    }

    fn raw(self: *XmlWriter, s: []const u8) !void {
        try self.buf.appendSlice(self.arena, s);
    }

    pub fn declaration(self: *XmlWriter) !void {
        try self.raw("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    }

    pub fn open(self: *XmlWriter, tag: []const u8) !void {
        try self.raw("<");
        try self.raw(tag);
        try self.raw(">");
    }

    pub fn close(self: *XmlWriter, tag: []const u8) !void {
        try self.raw("</");
        try self.raw(tag);
        try self.raw(">");
    }

    pub fn text(self: *XmlWriter, body: []const u8) !void {
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

    pub fn element(self: *XmlWriter, tag: []const u8, body: []const u8) !void {
        try self.open(tag);
        try self.text(body);
        try self.close(tag);
    }

    pub fn finish(self: *XmlWriter) []const u8 {
        return self.buf.items;
    }
};

pub fn writeError(arena: std.mem.Allocator, code: []const u8, message: []const u8, request_id: []const u8) ![]const u8 {
    var x = XmlWriter.init(arena);
    try x.declaration();
    try x.open("ErrorResponse");
    try x.open("Error");
    try x.element("Type", "Sender");
    try x.element("Code", code);
    try x.element("Message", message);
    try x.close("Error");
    try x.element("RequestId", request_id);
    try x.close("ErrorResponse");
    return x.finish();
}

const testing = std.testing;

test "pairs iterates in order" {
    var it = pairs("Action=Foo&Bar=baz");
    const a = it.next().?;
    try testing.expectEqualStrings("Action", a.key);
    try testing.expectEqualStrings("Foo", a.value);
    const b = it.next().?;
    try testing.expectEqualStrings("Bar", b.key);
    try testing.expectEqualStrings("baz", b.value);
    try testing.expect(it.next() == null);
}

test "percentDecode space and slash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a b", try percentDecode(arena.allocator(), "a%20b"));
    try testing.expectEqualStrings("a b", try percentDecode(arena.allocator(), "a+b"));
    try testing.expectEqualStrings("a/b", try percentDecode(arena.allocator(), "a%2Fb"));
}

test "extractAction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("CreateQueue", try extractAction(arena.allocator(), "Action=CreateQueue&QueueName=x"));
    try testing.expectError(error.MissingAction, extractAction(arena.allocator(), "QueueName=x"));
}

test "getIndexedMap pairs name/value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var m = try getIndexedMap("Attribute.1.Name=X&Attribute.1.Value=Y&Attribute.2.Name=A&Attribute.2.Value=B", arena.allocator(), "Attribute");
    try testing.expectEqualStrings("Y", m.get("X").?);
    try testing.expectEqualStrings("B", m.get("A").?);
    try testing.expectEqual(@as(usize, 2), m.count());
}

test "getIndexedList collects values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const list = try getIndexedList("Attribute.1.Name=VisibilityTimeout&Attribute.2.Name=DelaySeconds", arena.allocator(), "Attribute.{i}.Name");
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("VisibilityTimeout", list[0]);
    try testing.expectEqualStrings("DelaySeconds", list[1]);
}

test "xml declaration and escaping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var x = XmlWriter.init(arena.allocator());
    try x.declaration();
    try x.element("a", "<");
    try testing.expectEqualStrings("<?xml version=\"1.0\" encoding=\"UTF-8\"?><a>&lt;</a>", x.finish());
}

test "writeError xml shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try writeError(arena.allocator(), "InvalidAction", "bad", "rid-1");
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ErrorResponse><Error><Type>Sender</Type><Code>InvalidAction</Code><Message>bad</Message></Error><RequestId>rid-1</RequestId></ErrorResponse>",
        s,
    );
}
