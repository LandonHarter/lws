const std = @import("std");
const time = @import("core").time;
const types = @import("types.zig");
const item_store = @import("store/item_store.zig");
const key = @import("store/key.zig");
const schema_io = @import("persist/schema_io.zig");
const item_io = @import("persist/item_io.zig");

const Table = item_store.Table;
const Item = types.Item;
const TableSchema = types.TableSchema;

pub const ListOpts = struct {
    limit: usize = 0,
    exclusive_start: ?[]const u8 = null,
};

pub const ListPage = struct {
    names: []const []const u8,
    last_name: ?[]const u8 = null,
};

pub const TableStat = struct {
    name: []const u8,
    items: u64,
    bytes: u64,
};

pub const StatsSnapshot = struct {
    tables: u64 = 0,
    items: u64 = 0,
    bytes: u64 = 0,
    detail: []TableStat = &.{},
};

const TokenEntry = struct { token: []u8, body: []u8, ts_ms: i64 };
const token_ttl_ms: i64 = 10 * 60 * 1000;
const token_cap: usize = 256;

pub const Registry = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    fsync: bool,
    clock: time.Clock,
    rng: std.Random,
    tables_dir: []const u8,
    tables: std.StringArrayHashMapUnmanaged(*Table) = .empty,
    mutex: std.Io.Mutex = .init,
    txn_tokens: std.ArrayListUnmanaged(TokenEntry) = .empty,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        data_dir: []const u8,
        fsync: bool,
        clock: time.Clock,
        rng: std.Random,
    ) Registry {
        const tables_dir = std.fs.path.join(gpa, &.{ data_dir, "tables" }) catch @panic("OOM");
        return .{
            .gpa = gpa,
            .io = io,
            .data_dir = data_dir,
            .fsync = fsync,
            .clock = clock,
            .rng = rng,
            .tables_dir = tables_dir,
        };
    }

    pub fn deinit(self: *Registry) void {
        for (self.tables.values()) |t| destroyTable(self.gpa, t);
        self.tables.deinit(self.gpa);
        for (self.txn_tokens.items) |e| {
            self.gpa.free(e.token);
            self.gpa.free(e.body);
        }
        self.txn_tokens.deinit(self.gpa);
        self.gpa.free(self.tables_dir);
    }

    // Idempotency cache for TransactWriteItems' ClientRequestToken. Returns the
    // cached response body (duped into `out`) for a live token, else null.
    pub fn txnCacheGet(self: *Registry, out: std.mem.Allocator, token: []const u8) !?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now = self.clock.nowMs();
        for (self.txn_tokens.items) |e| {
            if (now - e.ts_ms <= token_ttl_ms and std.mem.eql(u8, e.token, token)) {
                return try out.dupe(u8, e.body);
            }
        }
        return null;
    }

    pub fn txnCachePut(self: *Registry, token: []const u8, body: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now = self.clock.nowMs();
        // Drop expired entries, then bound the buffer by evicting the oldest.
        var i: usize = 0;
        while (i < self.txn_tokens.items.len) {
            if (now - self.txn_tokens.items[i].ts_ms > token_ttl_ms) {
                const e = self.txn_tokens.orderedRemove(i);
                self.gpa.free(e.token);
                self.gpa.free(e.body);
            } else i += 1;
        }
        while (self.txn_tokens.items.len >= token_cap) {
            const e = self.txn_tokens.orderedRemove(0);
            self.gpa.free(e.token);
            self.gpa.free(e.body);
        }
        try self.txn_tokens.append(self.gpa, .{
            .token = try self.gpa.dupe(u8, token),
            .body = try self.gpa.dupe(u8, body),
            .ts_ms = now,
        });
    }

    fn destroyTable(gpa: std.mem.Allocator, t: *Table) void {
        const arena_ptr = t.arena;
        arena_ptr.deinit();
        gpa.destroy(arena_ptr);
    }

    // Allocates a Table (own arena, deep-cloned schema) but does not touch disk
    // or install the persist hook. Caller owns those + map insertion.
    fn buildTable(self: *Registry, schema: TableSchema, dir: []const u8) !*Table {
        const arena_ptr = try self.gpa.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.gpa);
        errdefer {
            arena_ptr.deinit();
            self.gpa.destroy(arena_ptr);
        }
        const a = arena_ptr.allocator();
        const cloned = try cloneSchema(a, schema);
        const t = try a.create(Table);
        t.* = Table.init(arena_ptr, self.io, cloned);
        t.dir = try a.dupe(u8, dir);
        t.fsync = self.fsync;
        return t;
    }

    fn installHook(self: *Registry, t: *Table) void {
        t.hook = .{ .ctx = self, .putFn = persistPut, .deleteFn = persistDelete };
    }

    fn tableDir(self: *Registry, a: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fs.path.join(a, &.{ self.tables_dir, name });
    }

    pub fn createTable(self: *Registry, schema: TableSchema) !*Table {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try schema_io.validateName(schema.name);
        if (self.tables.get(schema.name)) |existing| return existing;

        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const dir = try self.tableDir(sa, schema.name);

        var to_write = schema;
        to_write.status = .ACTIVE;
        if (to_write.created_at_ms == 0) to_write.created_at_ms = self.clock.nowMs();
        to_write.item_count = 0;
        to_write.bytes = 0;
        try schema_io.writeSchema(sa, self.io, dir, to_write, self.fsync);

        const t = try self.buildTable(to_write, dir);
        errdefer destroyTable(self.gpa, t);
        self.installHook(t);
        try self.tables.put(self.gpa, t.schema.name, t);
        return t;
    }

    pub fn deleteTable(self: *Registry, name: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const idx = self.tables.getIndex(name) orelse return error.TableNotFound;
        const t = self.tables.values()[idx];
        std.Io.Dir.cwd().deleteTree(self.io, t.dir) catch {};
        self.tables.orderedRemoveAt(idx);
        destroyTable(self.gpa, t);
    }

    pub fn lookup(self: *Registry, name: []const u8) ?*Table {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.tables.get(name);
    }

    // Sorted, paginated table names duped into `out`.
    pub fn list(self: *Registry, out: std.mem.Allocator, opts: ListOpts) !ListPage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const all = try out.alloc([]const u8, self.tables.count());
        for (self.tables.keys(), 0..) |n, i| all[i] = n;
        std.mem.sort([]const u8, all, {}, lessThanStr);

        var start: usize = 0;
        if (opts.exclusive_start) |cur| {
            for (all, 0..) |n, i| {
                if (std.mem.eql(u8, n, cur)) {
                    start = i + 1;
                    break;
                }
            }
        }

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var i = start;
        var last: ?[]const u8 = null;
        while (i < all.len) : (i += 1) {
            try names.append(out, try out.dupe(u8, all[i]));
            if (opts.limit != 0 and names.items.len >= opts.limit) {
                if (i + 1 < all.len) last = try out.dupe(u8, all[i]);
                break;
            }
        }
        return .{ .names = try names.toOwnedSlice(out), .last_name = last };
    }

    fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    // Aggregate table/item/byte counts plus per-table detail, duped into `out`.
    pub fn aggregateStats(self: *Registry, out: std.mem.Allocator) !StatsSnapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const detail = try out.alloc(TableStat, self.tables.count());
        var items: u64 = 0;
        var bytes: u64 = 0;
        for (self.tables.values(), 0..) |t, i| {
            t.mutex.lockUncancelable(self.io);
            defer t.mutex.unlock(self.io);
            detail[i] = .{ .name = try out.dupe(u8, t.schema.name), .items = t.schema.item_count, .bytes = t.schema.bytes };
            items += t.schema.item_count;
            bytes += t.schema.bytes;
        }
        std.mem.sort(TableStat, detail, {}, lessThanStat);
        return .{ .tables = self.tables.count(), .items = items, .bytes = bytes, .detail = detail };
    }

    fn lessThanStat(_: void, a: TableStat, b: TableStat) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }

    pub fn recover(self: *Registry) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        var dir = std.Io.Dir.cwd().openDir(self.io, self.tables_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            schema_io.validateName(entry.name) catch continue;
            const dirpath = try self.tableDir(sa, entry.name);
            const schema = schema_io.readSchema(sa, self.io, dirpath) catch continue;

            const t = try self.buildTable(schema, dirpath);
            errdefer destroyTable(self.gpa, t);
            t.schema.item_count = 0;
            t.schema.bytes = 0;

            // Load items into memory without re-persisting (hook stays off).
            const items = item_io.readAllItems(t.arena.allocator(), self.io, dirpath) catch &[_]Item{};
            for (items) |item| {
                _ = t.putItem(item, false) catch continue;
            }
            self.installHook(t);
            try self.tables.put(self.gpa, t.schema.name, t);
        }
    }

    fn persistSchemaNoLock(self: *Registry, t: *Table) !void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        try schema_io.writeSchema(scratch.allocator(), self.io, t.dir, t.schema, self.fsync);
    }

    // Enable/disable TTL and (re)set the attribute name. Persists the schema.
    pub fn updateTtl(self: *Registry, t: *Table, enabled: bool, attr: ?[]const u8) !void {
        t.mutex.lockUncancelable(self.io);
        defer t.mutex.unlock(self.io);
        const a = t.arena.allocator();
        t.schema.ttl_enabled = enabled;
        if (attr) |x| t.schema.ttl_attribute = try a.dupe(u8, x);
        try self.persistSchemaNoLock(t);
    }

    // Merge `incoming` into the table's tags, replacing values for existing keys.
    pub fn putTags(self: *Registry, t: *Table, incoming: []const types.Tag) !void {
        t.mutex.lockUncancelable(self.io);
        defer t.mutex.unlock(self.io);
        const a = t.arena.allocator();

        var merged: std.ArrayListUnmanaged(types.Tag) = .empty;
        for (t.schema.tags) |existing| try merged.append(a, existing);
        for (incoming) |tag| {
            var replaced = false;
            for (merged.items) |*m| {
                if (std.mem.eql(u8, m.key, tag.key)) {
                    m.value = try a.dupe(u8, tag.value);
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try merged.append(a, .{ .key = try a.dupe(u8, tag.key), .value = try a.dupe(u8, tag.value) });
        }
        t.schema.tags = try merged.toOwnedSlice(a);
        try self.persistSchemaNoLock(t);
    }

    // Drop tags whose key matches any in `keys`. Persists the schema.
    pub fn removeTags(self: *Registry, t: *Table, keys: []const []const u8) !void {
        t.mutex.lockUncancelable(self.io);
        defer t.mutex.unlock(self.io);
        const a = t.arena.allocator();

        var kept: std.ArrayListUnmanaged(types.Tag) = .empty;
        for (t.schema.tags) |tag| {
            var drop = false;
            for (keys) |k| if (std.mem.eql(u8, k, tag.key)) {
                drop = true;
                break;
            };
            if (!drop) try kept.append(a, tag);
        }
        t.schema.tags = try kept.toOwnedSlice(a);
        try self.persistSchemaNoLock(t);
    }

    // Set billing mode (UpdateTable echo); persists the schema.
    pub fn setBillingMode(self: *Registry, t: *Table, mode: types.BillingMode) !void {
        t.mutex.lockUncancelable(self.io);
        defer t.mutex.unlock(self.io);
        t.schema.billing_mode = mode;
        try self.persistSchemaNoLock(t);
    }

    // Append a GSI, register any new attribute defs, backfill existing items into
    // the index dir, then persist. Caller validates the index against attr defs.
    pub fn addIndex(self: *Registry, t: *Table, idx: types.SecondaryIndex, extra_defs: []const types.KeyDef) !void {
        t.mutex.lockUncancelable(self.io);
        defer t.mutex.unlock(self.io);
        const a = t.arena.allocator();

        const new_idxs = try a.alloc(types.SecondaryIndex, t.schema.indexes.len + 1);
        for (t.schema.indexes, 0..) |old, i| new_idxs[i] = old;
        new_idxs[t.schema.indexes.len] = try cloneIndex(a, idx);
        const added = &new_idxs[t.schema.indexes.len];
        t.schema.indexes = new_idxs;

        if (extra_defs.len != 0) {
            var defs: std.ArrayListUnmanaged(types.KeyDef) = .empty;
            for (t.schema.attribute_defs) |d| try defs.append(a, d);
            for (extra_defs) |d| {
                var dup = false;
                for (defs.items) |e| if (std.mem.eql(u8, e.name, d.name)) {
                    dup = true;
                    break;
                };
                if (!dup) try defs.append(a, .{ .name = try a.dupe(u8, d.name), .kind = d.kind });
            }
            t.schema.attribute_defs = try defs.toOwnedSlice(a);
        }

        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        for (t.entries.values()) |e| {
            const kb = indexKeyBytes(sa, e.item, added.*) orelse continue;
            const proj = try project(sa, e.item, added.*);
            try item_io.writeIndexItem(sa, self.io, t.dir, added.name, kb, e.key_enc, proj, self.fsync);
            _ = scratch.reset(.retain_capacity);
        }
        try self.persistSchemaNoLock(t);
    }

    // Remove a GSI/LSI by name and tear down its on-disk dir. Persists the schema.
    pub fn dropIndex(self: *Registry, t: *Table, idx_name: []const u8) !void {
        t.mutex.lockUncancelable(self.io);
        defer t.mutex.unlock(self.io);
        const a = t.arena.allocator();

        var kept: std.ArrayListUnmanaged(types.SecondaryIndex) = .empty;
        var found = false;
        for (t.schema.indexes) |idx| {
            if (std.mem.eql(u8, idx.name, idx_name)) {
                found = true;
                continue;
            }
            try kept.append(a, idx);
        }
        if (!found) return error.IndexNotFound;
        t.schema.indexes = try kept.toOwnedSlice(a);

        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const idx_dir = try std.fs.path.join(scratch.allocator(), &.{ t.dir, "indexes", idx_name });
        std.Io.Dir.cwd().deleteTree(self.io, idx_dir) catch {};
        try self.persistSchemaNoLock(t);
    }
};

// ---- persist hook: disk + index maintenance (fires under the table mutex) ----

fn persistPut(ctx: *anyopaque, table: *Table, key_enc: []const u8, prev: ?Item, next: Item) anyerror!void {
    const reg: *Registry = @ptrCast(@alignCast(ctx));
    var scratch = std.heap.ArenaAllocator.init(reg.gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    try item_io.writeItem(sa, table.io, table.dir, key_enc, next, table.fsync);

    for (table.schema.indexes) |idx| {
        const new_kb = indexKeyBytes(sa, next, idx);
        const old_kb = if (prev) |p| indexKeyBytes(sa, p, idx) else null;
        if (old_kb) |okb| {
            const same = new_kb != null and std.mem.eql(u8, okb, new_kb.?);
            if (!same) try item_io.deleteIndexItem(table.io, sa, table.dir, idx.name, okb, key_enc);
        }
        if (new_kb) |nkb| {
            const proj = try project(sa, next, idx);
            try item_io.writeIndexItem(sa, table.io, table.dir, idx.name, nkb, key_enc, proj, table.fsync);
        }
    }
}

fn persistDelete(ctx: *anyopaque, table: *Table, key_enc: []const u8, prev: Item) anyerror!void {
    const reg: *Registry = @ptrCast(@alignCast(ctx));
    var scratch = std.heap.ArenaAllocator.init(reg.gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    try item_io.deleteItem(table.io, sa, table.dir, key_enc);
    for (table.schema.indexes) |idx| {
        const kb = indexKeyBytes(sa, prev, idx) orelse continue;
        try item_io.deleteIndexItem(table.io, sa, table.dir, idx.name, kb, key_enc);
    }
}

// Encoded index key for an item, or null when the item lacks the index
// partition (or sort) key — a sparse index entry that we simply don't write.
fn indexKeyBytes(a: std.mem.Allocator, item: Item, idx: types.SecondaryIndex) ?[]u8 {
    const pk = key.partFromItem(item, idx.schema.partition) catch return null;
    const sk: ?key.Part = if (idx.schema.sort) |sd| (key.partFromItem(item, sd) catch return null) else null;
    return key.encode(a, pk, sk) catch null;
}

// Project an item for an index entry per its projection type. Base + index keys
// are always present; INCLUDE adds named attrs; ALL copies everything.
fn project(a: std.mem.Allocator, item: Item, idx: types.SecondaryIndex) !Item {
    if (idx.projection == .ALL) return item_store.cloneItem(a, item);

    var out: Item = .{};
    try copyAttrIfPresent(a, &out, item, idx.schema.partition.name);
    if (idx.schema.sort) |sd| try copyAttrIfPresent(a, &out, item, sd.name);
    if (idx.projection == .INCLUDE) {
        for (idx.projection.INCLUDE) |name| try copyAttrIfPresent(a, &out, item, name);
    }
    return out;
}

fn copyAttrIfPresent(a: std.mem.Allocator, out: *Item, item: Item, name: []const u8) !void {
    if (out.attrs.contains(name)) return;
    if (item.attrs.get(name)) |v| {
        try out.attrs.put(a, try a.dupe(u8, name), try item_store.cloneValue(a, v));
    }
}

fn cloneSchema(a: std.mem.Allocator, s: TableSchema) !TableSchema {
    var out: TableSchema = .{
        .name = try a.dupe(u8, s.name),
        .key_schema = try cloneKeySchema(a, s.key_schema),
        .billing_mode = s.billing_mode,
        .ttl_enabled = s.ttl_enabled,
        .table_id = try a.dupe(u8, s.table_id),
        .created_at_ms = s.created_at_ms,
        .status = s.status,
        .item_count = s.item_count,
        .bytes = s.bytes,
    };
    const tags = try a.alloc(types.Tag, s.tags.len);
    for (s.tags, 0..) |t, i| tags[i] = .{ .key = try a.dupe(u8, t.key), .value = try a.dupe(u8, t.value) };
    out.tags = tags;
    const defs = try a.alloc(types.KeyDef, s.attribute_defs.len);
    for (s.attribute_defs, 0..) |d, i| defs[i] = .{ .name = try a.dupe(u8, d.name), .kind = d.kind };
    out.attribute_defs = defs;

    const idxs = try a.alloc(types.SecondaryIndex, s.indexes.len);
    for (s.indexes, 0..) |idx, i| idxs[i] = try cloneIndex(a, idx);
    out.indexes = idxs;

    if (s.ttl_attribute) |t| out.ttl_attribute = try a.dupe(u8, t);
    return out;
}

fn cloneKeySchema(a: std.mem.Allocator, ks: types.KeySchema) !types.KeySchema {
    var out: types.KeySchema = .{
        .partition = .{ .name = try a.dupe(u8, ks.partition.name), .kind = ks.partition.kind },
    };
    if (ks.sort) |s| out.sort = .{ .name = try a.dupe(u8, s.name), .kind = s.kind };
    return out;
}

fn cloneIndex(a: std.mem.Allocator, idx: types.SecondaryIndex) !types.SecondaryIndex {
    var out: types.SecondaryIndex = .{
        .name = try a.dupe(u8, idx.name),
        .kind = idx.kind,
        .schema = try cloneKeySchema(a, idx.schema),
        .projection = idx.projection,
        .status = idx.status,
    };
    if (idx.projection == .INCLUDE) {
        const attrs = try a.alloc([]const u8, idx.projection.INCLUDE.len);
        for (idx.projection.INCLUDE, 0..) |n, i| attrs[i] = try a.dupe(u8, n);
        out.projection = .{ .INCLUDE = attrs };
    }
    return out;
}

const testing = std.testing;

fn tmpDataDir(buf: []u8, tmp: *const std.testing.TmpDir) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
}

fn testRegistry(io: std.Io, data_dir: []const u8, prng: *std.Random.DefaultPrng) Registry {
    return Registry.init(testing.allocator, io, data_dir, false, time.Clock.fixed(1717689600, 1717689600000), prng.random());
}

fn simpleSchema(name: []const u8) TableSchema {
    return .{ .name = name, .key_schema = .{ .partition = .{ .name = "id", .kind = .S } } };
}

test "create then lookup; idempotent; invalid name rejected" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var prng = std.Random.DefaultPrng.init(1);
    var reg = testRegistry(io, data_dir, &prng);
    defer reg.deinit();

    const t = try reg.createTable(simpleSchema("Orders"));
    try testing.expectEqualStrings("Orders", t.schema.name);
    try testing.expect(reg.lookup("Orders") == t);
    try testing.expect((reg.createTable(simpleSchema("Orders")) catch unreachable) == t);
    try testing.expect(reg.lookup("nope") == null);
    try testing.expectError(schema_io.NameError.InvalidTableName, reg.createTable(simpleSchema("ab")));
}

test "recover rebuilds 3 tables" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    {
        var prng = std.Random.DefaultPrng.init(2);
        var reg = testRegistry(io, data_dir, &prng);
        defer reg.deinit();
        _ = try reg.createTable(simpleSchema("alpha"));
        _ = try reg.createTable(simpleSchema("bravo"));
        _ = try reg.createTable(simpleSchema("charlie"));
    }

    var prng2 = std.Random.DefaultPrng.init(3);
    var reg2 = testRegistry(io, data_dir, &prng2);
    defer reg2.deinit();
    try reg2.recover();

    var abuf = std.heap.ArenaAllocator.init(testing.allocator);
    defer abuf.deinit();
    const page = try reg2.list(abuf.allocator(), .{});
    try testing.expectEqual(@as(usize, 3), page.names.len);
    try testing.expectEqualStrings("alpha", page.names[0]);
    try testing.expectEqualStrings("charlie", page.names[2]);
}

test "put items, recover, items + counts survive" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    {
        var prng = std.Random.DefaultPrng.init(4);
        var reg = testRegistry(io, data_dir, &prng);
        defer reg.deinit();
        const t = try reg.createTable(simpleSchema("Things"));
        const a = t.arena.allocator();
        var n: usize = 0;
        while (n < 5) : (n += 1) {
            var item: Item = .{};
            const id = try std.fmt.allocPrint(a, "id{d}", .{n});
            try item.attrs.put(a, "id", .{ .S = id });
            try item.attrs.put(a, "v", .{ .N = "1" });
            _ = try t.putItem(item, false);
        }
        try testing.expectEqual(@as(u64, 5), t.count());
    }

    var prng2 = std.Random.DefaultPrng.init(5);
    var reg2 = testRegistry(io, data_dir, &prng2);
    defer reg2.deinit();
    try reg2.recover();
    const t = reg2.lookup("Things") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 5), t.count());
}

test "GSI: put item, recover, query index by partition finds it" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var indexes = [_]types.SecondaryIndex{.{
        .name = "by-email",
        .kind = .GSI,
        .schema = .{ .partition = .{ .name = "email", .kind = .S } },
        .projection = .ALL,
    }};
    const schema: TableSchema = .{
        .name = "Users",
        .key_schema = .{ .partition = .{ .name = "id", .kind = .S } },
        .indexes = &indexes,
    };

    {
        var prng = std.Random.DefaultPrng.init(6);
        var reg = testRegistry(io, data_dir, &prng);
        defer reg.deinit();
        const t = try reg.createTable(schema);
        const a = t.arena.allocator();
        var item: Item = .{};
        try item.attrs.put(a, "id", .{ .S = "u1" });
        try item.attrs.put(a, "email", .{ .S = "a@b.com" });
        _ = try t.putItem(item, false);
    }

    var prng2 = std.Random.DefaultPrng.init(7);
    var reg2 = testRegistry(io, data_dir, &prng2);
    defer reg2.deinit();
    try reg2.recover();
    const t = reg2.lookup("Users") orelse return error.TestUnexpectedResult;

    var abuf = std.heap.ArenaAllocator.init(testing.allocator);
    defer abuf.deinit();
    const page = try t.queryIndex(abuf.allocator(), t.schema.indexes[0].schema, .{
        .partition = .{ .kind = .S, .bytes = "a@b.com" },
    }, .{});
    try testing.expectEqual(@as(usize, 1), page.items.len);
    try testing.expectEqualStrings("u1", page.items[0].attrs.get("id").?.S);
}

test "concurrency: 8 threads x 100 disjoint puts -> 800 items" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var prng = std.Random.DefaultPrng.init(8);
    var reg = testRegistry(io, data_dir, &prng);
    defer reg.deinit();
    const t = try reg.createTable(simpleSchema("Conc"));

    const Worker = struct {
        fn run(tbl: *Table, base: usize) void {
            var buf: [64]u8 = undefined;
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                var item: Item = .{};
                const id = std.fmt.bufPrint(&buf, "t{d}-{d}", .{ base, i }) catch unreachable;
                item.attrs.put(std.heap.page_allocator, "id", .{ .S = id }) catch unreachable;
                _ = tbl.putItem(item, false) catch unreachable;
                item.attrs.deinit(std.heap.page_allocator);
            }
        }
    };

    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*th, n| th.* = try std.Thread.spawn(.{}, Worker.run, .{ t, n });
    for (&threads) |th| th.join();

    try testing.expectEqual(@as(u64, 800), t.count());
}
