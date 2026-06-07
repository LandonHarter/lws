const std = @import("std");
const atomic = @import("atomic.zig");
const types = @import("../types.zig");
const key = @import("../store/key.zig");

const AttributeValue = types.AttributeValue;
const Item = types.Item;

pub const ReadError = error{InvalidItem};

const max_item_file_bytes = 512 * 1024;
const b64 = std.base64.standard;

pub fn itemsRoot(a: std.mem.Allocator, table_dir: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ table_dir, "items" });
}

pub fn itemPath(a: std.mem.Allocator, table_dir: []const u8, key_bytes: []const u8) ![]u8 {
    const hex = key.hashHex(key_bytes);
    const name = try std.fmt.allocPrint(a, "{s}.json", .{hex});
    return std.fs.path.join(a, &.{ table_dir, "items", name });
}

// indexes/<index>/<hash(idx-key)>/<hash(pk)>.json
pub fn indexItemPath(
    a: std.mem.Allocator,
    table_dir: []const u8,
    index_name: []const u8,
    idx_key_bytes: []const u8,
    pk_bytes: []const u8,
) ![]u8 {
    const idx_hex = key.hashHex(idx_key_bytes);
    const pk_hex = key.hashHex(pk_bytes);
    const name = try std.fmt.allocPrint(a, "{s}.json", .{pk_hex});
    return std.fs.path.join(a, &.{ table_dir, "indexes", index_name, &idx_hex, name });
}

pub fn writeItem(arena: std.mem.Allocator, io: std.Io, table_dir: []const u8, key_bytes: []const u8, item: Item, fsync: bool) !void {
    const root = try itemsRoot(arena, table_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, root);
    const path = try itemPath(arena, table_dir, key_bytes);
    const body = try encodeItem(arena, item);
    try atomic.writeAtomic(io, path, body, fsync);
}

pub fn deleteItem(io: std.Io, arena: std.mem.Allocator, table_dir: []const u8, key_bytes: []const u8) !void {
    const path = try itemPath(arena, table_dir, key_bytes);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn writeIndexItem(
    arena: std.mem.Allocator,
    io: std.Io,
    table_dir: []const u8,
    index_name: []const u8,
    idx_key_bytes: []const u8,
    pk_bytes: []const u8,
    item: Item,
    fsync: bool,
) !void {
    const path = try indexItemPath(arena, table_dir, index_name, idx_key_bytes, pk_bytes);
    const dir = std.fs.path.dirname(path) orelse return ReadError.InvalidItem;
    try std.Io.Dir.createDirPath(.cwd(), io, dir);
    const body = try encodeItem(arena, item);
    try atomic.writeAtomic(io, path, body, fsync);
}

pub fn deleteIndexItem(
    io: std.Io,
    arena: std.mem.Allocator,
    table_dir: []const u8,
    index_name: []const u8,
    idx_key_bytes: []const u8,
    pk_bytes: []const u8,
) !void {
    const path = try indexItemPath(arena, table_dir, index_name, idx_key_bytes, pk_bytes);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

// Reads + parses every items/*.json under table_dir. A file that fails to parse
// is skipped (half-written record). Items are allocated in `arena`.
pub fn readAllItems(arena: std.mem.Allocator, io: std.Io, table_dir: []const u8) ![]Item {
    const root = try itemsRoot(arena, table_dir);
    var out: std.ArrayListUnmanaged(Item) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.toOwnedSlice(arena),
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const path = try std.fs.path.join(arena, &.{ root, entry.name });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, std.Io.Limit.limited(max_item_file_bytes)) catch continue;
        const item = parseItem(arena, bytes) catch continue;
        try out.append(arena, item);
    }
    return out.toOwnedSlice(arena);
}

// ---- AttributeValue <-> JSON (DynamoDB wire form) ----

pub fn encodeItem(arena: std.mem.Allocator, item: Item) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.writeByte('{');
    var it = item.attrs.iterator();
    var first = true;
    while (it.next()) |kv| {
        if (!first) try w.writeByte(',');
        first = false;
        try writeJsonString(w, kv.key_ptr.*);
        try w.writeByte(':');
        try writeValue(arena, w, kv.value_ptr.*);
    }
    try w.writeByte('}');
    return aw.written();
}

fn writeValue(arena: std.mem.Allocator, w: *std.Io.Writer, v: AttributeValue) !void {
    switch (v) {
        .S => |s| {
            try w.writeAll("{\"S\":");
            try writeJsonString(w, s);
            try w.writeByte('}');
        },
        .N => |s| {
            try w.writeAll("{\"N\":");
            try writeJsonString(w, s);
            try w.writeByte('}');
        },
        .B => |s| {
            try w.writeAll("{\"B\":");
            try writeBase64(arena, w, s);
            try w.writeByte('}');
        },
        .BOOL => |b| try w.print("{{\"BOOL\":{s}}}", .{if (b) "true" else "false"}),
        .NULL => try w.writeAll("{\"NULL\":true}"),
        .L => |l| {
            try w.writeAll("{\"L\":[");
            for (l, 0..) |e, i| {
                if (i != 0) try w.writeByte(',');
                try writeValue(arena, w, e);
            }
            try w.writeAll("]}");
        },
        .M => |m| {
            try w.writeAll("{\"M\":{");
            var it = m.iterator();
            var first = true;
            while (it.next()) |kv| {
                if (!first) try w.writeByte(',');
                first = false;
                try writeJsonString(w, kv.key_ptr.*);
                try w.writeByte(':');
                try writeValue(arena, w, kv.value_ptr.*);
            }
            try w.writeAll("}}");
        },
        .SS => |set| try writeStringArray(w, "SS", set),
        .NS => |set| try writeStringArray(w, "NS", set),
        .BS => |set| {
            try w.writeAll("{\"BS\":[");
            for (set, 0..) |e, i| {
                if (i != 0) try w.writeByte(',');
                try writeBase64(arena, w, e);
            }
            try w.writeAll("]}");
        },
    }
}

fn writeStringArray(w: *std.Io.Writer, tag: []const u8, set: []const []const u8) !void {
    try w.print("{{\"{s}\":[", .{tag});
    for (set, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        try writeJsonString(w, e);
    }
    try w.writeAll("]}");
}

fn writeBase64(arena: std.mem.Allocator, w: *std.Io.Writer, raw: []const u8) !void {
    const enc = try arena.alloc(u8, b64.Encoder.calcSize(raw.len));
    _ = b64.Encoder.encode(enc, raw);
    try writeJsonString(w, enc);
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c);
            },
        }
    }
    try w.writeByte('"');
}

pub fn parseItem(arena: std.mem.Allocator, bytes: []const u8) !Item {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (root != .object) return ReadError.InvalidItem;
    var item: Item = .{};
    var it = root.object.iterator();
    while (it.next()) |kv| {
        const v = try parseValue(arena, kv.value_ptr.*);
        try item.attrs.put(arena, try arena.dupe(u8, kv.key_ptr.*), v);
    }
    return item;
}

fn parseValue(arena: std.mem.Allocator, v: std.json.Value) !AttributeValue {
    if (v != .object) return ReadError.InvalidItem;
    const obj = v.object;
    if (obj.count() != 1) return ReadError.InvalidItem;
    var it = obj.iterator();
    const e = it.next().?;
    const tag = e.key_ptr.*;
    const val = e.value_ptr.*;

    if (std.mem.eql(u8, tag, "S")) {
        if (val != .string) return ReadError.InvalidItem;
        return .{ .S = try arena.dupe(u8, val.string) };
    } else if (std.mem.eql(u8, tag, "N")) {
        if (val != .string) return ReadError.InvalidItem;
        return .{ .N = try arena.dupe(u8, val.string) };
    } else if (std.mem.eql(u8, tag, "B")) {
        if (val != .string) return ReadError.InvalidItem;
        return .{ .B = try decodeBase64(arena, val.string) };
    } else if (std.mem.eql(u8, tag, "BOOL")) {
        if (val != .bool) return ReadError.InvalidItem;
        return .{ .BOOL = val.bool };
    } else if (std.mem.eql(u8, tag, "NULL")) {
        return .NULL;
    } else if (std.mem.eql(u8, tag, "L")) {
        if (val != .array) return ReadError.InvalidItem;
        const out = try arena.alloc(AttributeValue, val.array.items.len);
        for (val.array.items, 0..) |elem, i| out[i] = try parseValue(arena, elem);
        return .{ .L = out };
    } else if (std.mem.eql(u8, tag, "M")) {
        if (val != .object) return ReadError.InvalidItem;
        var m: std.StringArrayHashMapUnmanaged(AttributeValue) = .empty;
        var mit = val.object.iterator();
        while (mit.next()) |kv| {
            try m.put(arena, try arena.dupe(u8, kv.key_ptr.*), try parseValue(arena, kv.value_ptr.*));
        }
        return .{ .M = m };
    } else if (std.mem.eql(u8, tag, "SS")) {
        return .{ .SS = try parseStringArray(arena, val) };
    } else if (std.mem.eql(u8, tag, "NS")) {
        return .{ .NS = try parseStringArray(arena, val) };
    } else if (std.mem.eql(u8, tag, "BS")) {
        if (val != .array) return ReadError.InvalidItem;
        const out = try arena.alloc([]const u8, val.array.items.len);
        for (val.array.items, 0..) |elem, i| {
            if (elem != .string) return ReadError.InvalidItem;
            out[i] = try decodeBase64(arena, elem.string);
        }
        return .{ .BS = out };
    }
    return ReadError.InvalidItem;
}

fn parseStringArray(arena: std.mem.Allocator, val: std.json.Value) ![][]const u8 {
    if (val != .array) return ReadError.InvalidItem;
    const out = try arena.alloc([]const u8, val.array.items.len);
    for (val.array.items, 0..) |elem, i| {
        if (elem != .string) return ReadError.InvalidItem;
        out[i] = try arena.dupe(u8, elem.string);
    }
    return out;
}

fn decodeBase64(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    const n = b64.Decoder.calcSizeForSlice(s) catch return ReadError.InvalidItem;
    const out = try arena.alloc(u8, n);
    b64.Decoder.decode(out, s) catch return ReadError.InvalidItem;
    return out;
}

const testing = std.testing;

test "item JSON round-trip preserves every AttributeValue shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var item: Item = .{};
    try item.attrs.put(a, "s", .{ .S = "hello" });
    try item.attrs.put(a, "n", .{ .N = "42" });
    try item.attrs.put(a, "b", .{ .B = &[_]u8{ 0x00, 0xff, 0x10 } });
    try item.attrs.put(a, "bool", .{ .BOOL = true });
    try item.attrs.put(a, "null", .NULL);
    var list = [_]AttributeValue{ .{ .S = "a" }, .{ .N = "1" } };
    try item.attrs.put(a, "l", .{ .L = &list });
    var m: std.StringArrayHashMapUnmanaged(AttributeValue) = .empty;
    try m.put(a, "inner", .{ .S = "x" });
    try item.attrs.put(a, "m", .{ .M = m });
    var ss = [_][]const u8{ "a", "b" };
    try item.attrs.put(a, "ss", .{ .SS = &ss });
    var ns = [_][]const u8{ "1", "2" };
    try item.attrs.put(a, "ns", .{ .NS = &ns });
    var bs = [_][]const u8{ &[_]u8{ 0x01, 0x02 }, &[_]u8{0xaa} };
    try item.attrs.put(a, "bs", .{ .BS = &bs });

    const body = try encodeItem(a, item);
    const got = try parseItem(a, body);

    try testing.expectEqualStrings("hello", got.attrs.get("s").?.S);
    try testing.expectEqualStrings("42", got.attrs.get("n").?.N);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0xff, 0x10 }, got.attrs.get("b").?.B);
    try testing.expect(got.attrs.get("bool").?.BOOL);
    try testing.expect(got.attrs.get("null").? == .NULL);
    try testing.expectEqual(@as(usize, 2), got.attrs.get("l").?.L.len);
    try testing.expectEqualStrings("x", got.attrs.get("m").?.M.get("inner").?.S);
    try testing.expectEqual(@as(usize, 2), got.attrs.get("ss").?.SS.len);
    try testing.expectEqualStrings("2", got.attrs.get("ns").?.NS[1]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, got.attrs.get("bs").?.BS[0]);
}

test "writeItem + readAllItems round-trip on disk" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const table_dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var item: Item = .{};
        const id = try std.fmt.allocPrint(a, "id{d}", .{i});
        try item.attrs.put(a, "id", .{ .S = id });
        const kb = try key.encode(a, .{ .kind = .S, .bytes = id }, null);
        try writeItem(a, io, table_dir, kb, item, false);
    }

    const items = try readAllItems(a, io, table_dir);
    try testing.expectEqual(@as(usize, 3), items.len);

    // delete one, reload -> 2
    const kb0 = try key.encode(a, .{ .kind = .S, .bytes = "id0" }, null);
    try deleteItem(io, a, table_dir, kb0);
    const items2 = try readAllItems(a, io, table_dir);
    try testing.expectEqual(@as(usize, 2), items2.len);
}

test "readAllItems on missing dir returns empty" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const table_dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/nope", .{tmp.sub_path});
    const items = try readAllItems(a, io, table_dir);
    try testing.expectEqual(@as(usize, 0), items.len);
}
