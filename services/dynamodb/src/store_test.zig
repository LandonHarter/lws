const std = @import("std");
const types = @import("types.zig");
const key = @import("store/key.zig");
const item_store = @import("store/item_store.zig");

comptime {
    _ = types;
    _ = key;
    _ = item_store;
}

const testing = std.testing;

const Table = item_store.Table;

fn newTable(arena: *std.heap.ArenaAllocator, io: std.Io, schema: types.TableSchema) Table {
    return Table.init(arena, io, schema);
}

fn strItem(a: std.mem.Allocator, pk_name: []const u8, pk: []const u8, sk_name: ?[]const u8, sk: ?[]const u8) !types.Item {
    var item: types.Item = .{};
    try item.attrs.put(a, pk_name, .{ .S = pk });
    if (sk_name) |n| try item.attrs.put(a, n, .{ .N = sk.? });
    return item;
}

test "put/get/delete round-trip" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema: types.TableSchema = .{
        .name = "t",
        .key_schema = .{ .partition = .{ .name = "id", .kind = .S } },
    };
    var tbl = newTable(&arena, io, schema);

    var item: types.Item = .{};
    try item.attrs.put(a, "id", .{ .S = "abc" });
    try item.attrs.put(a, "v", .{ .N = "1" });
    _ = try tbl.putItem(item, false);
    try testing.expectEqual(@as(u64, 1), tbl.count());

    const enc = try key.encode(a, .{ .kind = .S, .bytes = "abc" }, null);
    const got = tbl.getItem(enc) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("1", got.attrs.get("v").?.N);

    const old = try tbl.deleteItem(enc, true);
    try testing.expect(old != null);
    try testing.expectEqual(@as(u64, 0), tbl.count());
    try testing.expect(tbl.getItem(enc) == null);
}

test "updateItem upserts and applies set/remove" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema: types.TableSchema = .{
        .name = "t",
        .key_schema = .{ .partition = .{ .name = "id", .kind = .S } },
    };
    var tbl = newTable(&arena, io, schema);

    var key_attrs: types.Item = .{};
    try key_attrs.attrs.put(a, "id", .{ .S = "k1" });
    const enc = try key.encode(a, .{ .kind = .S, .bytes = "k1" }, null);

    const actions = [_]item_store.UpdateAction{
        .{ .set = .{ .name = "name", .value = .{ .S = "alice" } } },
        .{ .set = .{ .name = "age", .value = .{ .N = "30" } } },
    };
    _ = try tbl.updateItem(enc, key_attrs, &actions);
    try testing.expectEqual(@as(u64, 1), tbl.count());
    var got = tbl.getItem(enc).?;
    try testing.expectEqualStrings("alice", got.attrs.get("name").?.S);

    const actions2 = [_]item_store.UpdateAction{
        .{ .remove = "name" },
        .{ .set = .{ .name = "age", .value = .{ .N = "31" } } },
    };
    _ = try tbl.updateItem(enc, key_attrs, &actions2);
    got = tbl.getItem(enc).?;
    try testing.expect(got.attrs.get("name") == null);
    try testing.expectEqualStrings("31", got.attrs.get("age").?.N);
    try testing.expectEqual(@as(u64, 1), tbl.count());
}

test "item too large rejected" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema: types.TableSchema = .{
        .name = "t",
        .key_schema = .{ .partition = .{ .name = "id", .kind = .S } },
    };
    var tbl = newTable(&arena, io, schema);

    const big = try a.alloc(u8, item_store.max_item_bytes + 1);
    @memset(big, 'x');
    var item: types.Item = .{};
    try item.attrs.put(a, "id", .{ .S = "x" });
    try item.attrs.put(a, "blob", .{ .B = big });
    try testing.expectError(item_store.StoreError.ItemTooLarge, tbl.putItem(item, false));
}

test "sort-key range queries" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema: types.TableSchema = .{
        .name = "t",
        .key_schema = .{
            .partition = .{ .name = "pk", .kind = .S },
            .sort = .{ .name = "sk", .kind = .N },
        },
    };
    var tbl = newTable(&arena, io, schema);

    var n: i64 = 1;
    while (n <= 5) : (n += 1) {
        const sv = try std.fmt.allocPrint(a, "{d}", .{n});
        const item = try strItem(a, "pk", "p", "sk", sv);
        _ = try tbl.putItem(item, false);
    }

    const pk: key.Part = .{ .kind = .S, .bytes = "p" };

    // lt 3 -> {1,2}
    {
        const page = try tbl.query(a, .{ .partition = pk, .sort_op = .lt, .sort_a = .{ .kind = .N, .bytes = "3" } }, .{});
        try testing.expectEqual(@as(usize, 2), page.items.len);
        try testing.expectEqualStrings("1", page.items[0].attrs.get("sk").?.N);
        try testing.expectEqualStrings("2", page.items[1].attrs.get("sk").?.N);
    }
    // le 3 -> {1,2,3}
    {
        const page = try tbl.query(a, .{ .partition = pk, .sort_op = .le, .sort_a = .{ .kind = .N, .bytes = "3" } }, .{});
        try testing.expectEqual(@as(usize, 3), page.items.len);
    }
    // between 2 and 4 -> {2,3,4}
    {
        const page = try tbl.query(a, .{ .partition = pk, .sort_op = .between, .sort_a = .{ .kind = .N, .bytes = "2" }, .sort_b = .{ .kind = .N, .bytes = "4" } }, .{});
        try testing.expectEqual(@as(usize, 3), page.items.len);
        try testing.expectEqualStrings("2", page.items[0].attrs.get("sk").?.N);
        try testing.expectEqualStrings("4", page.items[2].attrs.get("sk").?.N);
    }
    // reverse order
    {
        const page = try tbl.query(a, .{ .partition = pk }, .{ .forward = false });
        try testing.expectEqual(@as(usize, 5), page.items.len);
        try testing.expectEqualStrings("5", page.items[0].attrs.get("sk").?.N);
    }
}

test "begins_with on string sort key" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema: types.TableSchema = .{
        .name = "t",
        .key_schema = .{
            .partition = .{ .name = "pk", .kind = .S },
            .sort = .{ .name = "sk", .kind = .S },
        },
    };
    var tbl = newTable(&arena, io, schema);

    for ([_][]const u8{ "user#1", "user#2", "admin#1" }) |sk| {
        var item: types.Item = .{};
        try item.attrs.put(a, "pk", .{ .S = "p" });
        try item.attrs.put(a, "sk", .{ .S = sk });
        _ = try tbl.putItem(item, false);
    }
    const page = try tbl.query(a, .{
        .partition = .{ .kind = .S, .bytes = "p" },
        .sort_op = .begins_with,
        .sort_a = .{ .kind = .S, .bytes = "user#" },
    }, .{});
    try testing.expectEqual(@as(usize, 2), page.items.len);
}

test "pagination walks 50 items in 5 pages without duplicates" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema: types.TableSchema = .{
        .name = "t",
        .key_schema = .{ .partition = .{ .name = "id", .kind = .S } },
    };
    var tbl = newTable(&arena, io, schema);

    var seen = std.StringArrayHashMapUnmanaged(void).empty;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const id = try std.fmt.allocPrint(a, "id-{d:0>3}", .{i});
        var item: types.Item = .{};
        try item.attrs.put(a, "id", .{ .S = id });
        _ = try tbl.putItem(item, false);
    }

    var cursor: ?[]const u8 = null;
    var pages: usize = 0;
    var total: usize = 0;
    while (true) {
        const page = try tbl.scan(a, .{ .limit = 10, .exclusive_start = cursor });
        pages += 1;
        total += page.items.len;
        for (page.items) |it| {
            const id = it.attrs.get("id").?.S;
            try testing.expect(!seen.contains(id));
            try seen.put(a, id, {});
        }
        if (page.last_key == null) break;
        cursor = page.last_key;
    }
    try testing.expectEqual(@as(usize, 5), pages);
    try testing.expectEqual(@as(usize, 50), total);
}
