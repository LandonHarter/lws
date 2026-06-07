const std = @import("std");
const types = @import("../types.zig");
const key = @import("key.zig");

const AttributeValue = types.AttributeValue;
const Item = types.Item;
const TableSchema = types.TableSchema;

pub const max_item_bytes: u64 = 400 * 1024;

pub const StoreError = error{ItemTooLarge};

// A stored item plus its decoded key parts (pointing into the arena copy) so
// query/scan can filter without re-decoding the map key.
const Entry = struct {
    key_enc: []const u8,
    pk: key.Part,
    sk: ?key.Part,
    item: Item,
};

pub const SortOp = enum { none, eq, lt, le, gt, ge, between, begins_with };

pub const KeyCondition = struct {
    partition: key.Part,
    sort_op: SortOp = .none,
    sort_a: ?key.Part = null,
    sort_b: ?key.Part = null,
};

pub const ScanOpts = struct {
    limit: usize = 0,
    exclusive_start: ?[]const u8 = null,
};

pub const QueryOpts = struct {
    limit: usize = 0,
    exclusive_start: ?[]const u8 = null,
    forward: bool = true,
};

pub const Page = struct {
    items: []Item,
    last_key: ?[]const u8 = null,
};

pub const UpdateAction = union(enum) {
    set: struct { name: []const u8, value: AttributeValue },
    remove: []const u8,
};

// Hook the registry installs so it can mirror writes onto disk and maintain
// index dirs. Fires while the table mutex is held. `prev` is the item being
// replaced (null on first insert) so the hook can delete stale index entries.
pub const PersistHook = struct {
    ctx: *anyopaque,
    putFn: *const fn (ctx: *anyopaque, table: *Table, key_enc: []const u8, prev: ?Item, next: Item) anyerror!void,
    deleteFn: *const fn (ctx: *anyopaque, table: *Table, key_enc: []const u8, prev: Item) anyerror!void,
};

pub const Table = struct {
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    schema: TableSchema,
    entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    mutex: std.Io.Mutex = .init,
    hook: ?PersistHook = null,
    dir: []const u8 = "", // on-disk table dir; set by the registry
    fsync: bool = false,

    pub fn init(arena: *std.heap.ArenaAllocator, io: std.Io, schema: TableSchema) Table {
        return .{ .arena = arena, .io = io, .schema = schema };
    }

    fn alloc(self: *Table) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn count(self: *Table) u64 {
        return self.schema.item_count;
    }

    pub fn bytes(self: *Table) u64 {
        return self.schema.bytes;
    }

    // Insert or replace. Returns the previous item if `return_old`. Errors if the
    // item exceeds the 400 KB wire-size cap.
    pub fn putItem(self: *Table, item: Item, return_old: bool) !?Item {
        const sz = itemBytes(item);
        if (sz > max_item_bytes) return StoreError.ItemTooLarge;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const a = self.alloc();
        const cloned = try cloneItem(a, item);
        const enc = try key.encodeFromItem(a, cloned, self.schema.key_schema);
        const pk = try key.partFromItem(cloned, self.schema.key_schema.partition);
        const sk: ?key.Part = if (self.schema.key_schema.sort) |sd| try key.partFromItem(cloned, sd) else null;

        var old: ?Item = null;
        var prev: ?Item = null;
        if (self.entries.get(enc)) |existing| {
            prev = existing.item;
            old = if (return_old) existing.item else null;
            self.schema.bytes -= itemBytes(existing.item);
            self.schema.bytes += sz;
            try self.entries.put(a, enc, .{ .key_enc = enc, .pk = pk, .sk = sk, .item = cloned });
        } else {
            try self.entries.put(a, enc, .{ .key_enc = enc, .pk = pk, .sk = sk, .item = cloned });
            self.schema.item_count += 1;
            self.schema.bytes += sz;
        }
        if (self.hook) |h| try h.putFn(h.ctx, self, enc, prev, cloned);
        return old;
    }

    pub fn getItem(self: *Table, key_enc: []const u8) ?Item {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.entries.get(key_enc)) |e| return e.item;
        return null;
    }

    pub fn deleteItem(self: *Table, key_enc: []const u8, return_old: bool) !?Item {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const idx = self.entries.getIndex(key_enc) orelse return null;
        const e = self.entries.values()[idx];
        const prev = e.item;
        const old: ?Item = if (return_old) e.item else null;
        self.schema.bytes -= itemBytes(e.item);
        self.schema.item_count -= 1;
        self.entries.orderedRemoveAt(idx);
        if (self.hook) |h| try h.deleteFn(h.ctx, self, key_enc, prev);
        return old;
    }

    // Apply set/remove actions to an existing item, creating it (upsert) if it is
    // absent — matches DynamoDB UpdateItem. `key_attrs` seeds a new item with its
    // primary key when upserting.
    pub fn updateItem(self: *Table, key_enc: []const u8, key_attrs: Item, actions: []const UpdateAction) !Item {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const a = self.alloc();
        var next: Item = .{};
        var existed = false;
        var prev_bytes: u64 = 0;
        var prev: ?Item = null;
        if (self.entries.get(key_enc)) |e| {
            existed = true;
            prev = e.item;
            prev_bytes = itemBytes(e.item);
            var it = e.item.attrs.iterator();
            while (it.next()) |kv| {
                try next.attrs.put(a, try a.dupe(u8, kv.key_ptr.*), try cloneValue(a, kv.value_ptr.*));
            }
        } else {
            var it = key_attrs.attrs.iterator();
            while (it.next()) |kv| {
                try next.attrs.put(a, try a.dupe(u8, kv.key_ptr.*), try cloneValue(a, kv.value_ptr.*));
            }
        }

        for (actions) |act| switch (act) {
            .set => |s| try next.attrs.put(a, try a.dupe(u8, s.name), try cloneValue(a, s.value)),
            .remove => |name| {
                _ = next.attrs.orderedRemove(name);
            },
        };

        const sz = itemBytes(next);
        if (sz > max_item_bytes) return StoreError.ItemTooLarge;

        const enc = try key.encodeFromItem(a, next, self.schema.key_schema);
        const pk = try key.partFromItem(next, self.schema.key_schema.partition);
        const sk: ?key.Part = if (self.schema.key_schema.sort) |sd| try key.partFromItem(next, sd) else null;

        try self.entries.put(a, enc, .{ .key_enc = enc, .pk = pk, .sk = sk, .item = next });
        if (existed) {
            self.schema.bytes = self.schema.bytes - prev_bytes + sz;
        } else {
            self.schema.item_count += 1;
            self.schema.bytes += sz;
        }
        if (self.hook) |h| try h.putFn(h.ctx, self, enc, prev, next);
        return next;
    }

    // A mutation a `mutate` callback asks the table to apply atomically under the
    // write lock. `put` and `delete` carry the new state (already allocated in the
    // table arena); `none` is a condition-only check (TransactWrite ConditionCheck).
    pub const Mutation = union(enum) {
        put: Item,
        delete,
        none,
    };

    pub const Decision = union(enum) {
        proceed: Mutation,
        condition_failed,
    };

    // Computes a Decision from the current item (null when absent). Receives the
    // table arena so it can allocate the resulting item in-place.
    pub const MutateFn = *const fn (ctx: *anyopaque, current: ?Item, a: std.mem.Allocator) anyerror!Decision;

    pub const MutateOutcome = struct {
        applied: bool, // false when the condition failed
        old: ?Item, // item present before the mutation
    };

    // Read-modify-write under the table lock so conditional puts/updates/deletes
    // evaluate against — and commit relative to — a consistent snapshot.
    pub fn mutate(self: *Table, key_enc: []const u8, ctx: *anyopaque, f: MutateFn) !MutateOutcome {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const a = self.alloc();
        const current: ?Item = if (self.entries.get(key_enc)) |e| e.item else null;
        const decision = try f(ctx, current, a);
        switch (decision) {
            .condition_failed => return .{ .applied = false, .old = null },
            .proceed => |m| switch (m) {
                .none => return .{ .applied = true, .old = current },
                .delete => {
                    if (self.entries.getIndex(key_enc)) |idx| {
                        const e = self.entries.values()[idx];
                        self.schema.bytes -= itemBytes(e.item);
                        self.schema.item_count -= 1;
                        self.entries.orderedRemoveAt(idx);
                        if (self.hook) |h| try h.deleteFn(h.ctx, self, key_enc, e.item);
                    }
                    return .{ .applied = true, .old = current };
                },
                .put => |next| {
                    const sz = itemBytes(next);
                    if (sz > max_item_bytes) return StoreError.ItemTooLarge;
                    const pk = try key.partFromItem(next, self.schema.key_schema.partition);
                    const sk: ?key.Part = if (self.schema.key_schema.sort) |sd| try key.partFromItem(next, sd) else null;
                    var prev: ?Item = null;
                    if (self.entries.get(key_enc)) |existing| {
                        prev = existing.item;
                        self.schema.bytes -= itemBytes(existing.item);
                        self.schema.bytes += sz;
                    } else {
                        self.schema.item_count += 1;
                        self.schema.bytes += sz;
                    }
                    const enc = try a.dupe(u8, key_enc);
                    try self.entries.put(a, enc, .{ .key_enc = enc, .pk = pk, .sk = sk, .item = next });
                    if (self.hook) |h| try h.putFn(h.ctx, self, enc, prev, next);
                    return .{ .applied = true, .old = current };
                },
            },
        }
    }

    // Linear scan in insertion order. Honors a page `limit` and an
    // `exclusive_start` (encoded key) cursor.
    pub fn scan(self: *Table, out: std.mem.Allocator, opts: ScanOpts) !Page {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var start: usize = 0;
        if (opts.exclusive_start) |cur| {
            if (self.entries.getIndex(cur)) |i| start = i + 1;
        }

        var collected: std.ArrayListUnmanaged(Item) = .empty;
        const vals = self.entries.values();
        var i = start;
        var last: ?[]const u8 = null;
        while (i < vals.len) : (i += 1) {
            try collected.append(out, vals[i].item);
            if (opts.limit != 0 and collected.items.len >= opts.limit) {
                if (i + 1 < vals.len) last = try out.dupe(u8, vals[i].key_enc);
                break;
            }
        }
        return .{ .items = try collected.toOwnedSlice(out), .last_key = last };
    }

    // Query a single partition, filtered by an optional sort-key condition,
    // returned in sort-key order (or reverse when `forward` is false).
    pub fn query(self: *Table, out: std.mem.Allocator, cond: KeyCondition, opts: QueryOpts) !Page {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var matched: std.ArrayListUnmanaged(Entry) = .empty;
        defer matched.deinit(out);
        for (self.entries.values()) |e| {
            if (key.comparePart(e.pk, cond.partition) != .eq) continue;
            if (!matchSort(e.sk, cond)) continue;
            try matched.append(out, e);
        }
        std.mem.sort(Entry, matched.items, {}, entryLessThan);
        if (!opts.forward) std.mem.reverse(Entry, matched.items);

        var start: usize = 0;
        if (opts.exclusive_start) |cur| {
            for (matched.items, 0..) |e, idx| {
                if (std.mem.eql(u8, e.key_enc, cur)) {
                    start = idx + 1;
                    break;
                }
            }
        }

        var collected: std.ArrayListUnmanaged(Item) = .empty;
        var i = start;
        var last: ?[]const u8 = null;
        while (i < matched.items.len) : (i += 1) {
            try collected.append(out, matched.items[i].item);
            if (opts.limit != 0 and collected.items.len >= opts.limit) {
                if (i + 1 < matched.items.len) last = try out.dupe(u8, matched.items[i].key_enc);
                break;
            }
        }
        return .{ .items = try collected.toOwnedSlice(out), .last_key = last };
    }

    // Query a secondary index by re-deriving its key from each base item. An
    // item missing the index partition key is sparse and excluded. Results are
    // ordered by the index sort key.
    pub fn queryIndex(self: *Table, out: std.mem.Allocator, index_schema: types.KeySchema, cond: KeyCondition, opts: QueryOpts) !Page {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const IdxMatch = struct { key_enc: []const u8, sk: ?key.Part, item: Item };
        var matched: std.ArrayListUnmanaged(IdxMatch) = .empty;
        defer matched.deinit(out);
        for (self.entries.values()) |e| {
            const pk = key.partFromItem(e.item, index_schema.partition) catch continue;
            if (key.comparePart(pk, cond.partition) != .eq) continue;
            const sk: ?key.Part = if (index_schema.sort) |sd| (key.partFromItem(e.item, sd) catch continue) else null;
            if (!matchSort(sk, cond)) continue;
            try matched.append(out, .{ .key_enc = e.key_enc, .sk = sk, .item = e.item });
        }
        std.mem.sort(IdxMatch, matched.items, {}, struct {
            fn lt(_: void, a: IdxMatch, b: IdxMatch) bool {
                const sa = a.sk orelse return false;
                const sb = b.sk orelse return false;
                return key.comparePart(sa, sb) == .lt;
            }
        }.lt);
        if (!opts.forward) std.mem.reverse(IdxMatch, matched.items);

        var start: usize = 0;
        if (opts.exclusive_start) |cur| {
            for (matched.items, 0..) |m, idx| {
                if (std.mem.eql(u8, m.key_enc, cur)) {
                    start = idx + 1;
                    break;
                }
            }
        }

        var collected: std.ArrayListUnmanaged(Item) = .empty;
        var i = start;
        var last: ?[]const u8 = null;
        while (i < matched.items.len) : (i += 1) {
            try collected.append(out, matched.items[i].item);
            if (opts.limit != 0 and collected.items.len >= opts.limit) {
                if (i + 1 < matched.items.len) last = try out.dupe(u8, matched.items[i].key_enc);
                break;
            }
        }
        return .{ .items = try collected.toOwnedSlice(out), .last_key = last };
    }
};

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    const sa = a.sk orelse return false;
    const sb = b.sk orelse return false;
    return key.comparePart(sa, sb) == .lt;
}

fn matchSort(sk: ?key.Part, cond: KeyCondition) bool {
    if (cond.sort_op == .none) return true;
    const s = sk orelse return false;
    const a = cond.sort_a orelse return false;
    return switch (cond.sort_op) {
        .none => true,
        .eq => key.comparePart(s, a) == .eq,
        .lt => key.comparePart(s, a) == .lt,
        .le => key.comparePart(s, a) != .gt,
        .gt => key.comparePart(s, a) == .gt,
        .ge => key.comparePart(s, a) != .lt,
        .between => blk: {
            const b = cond.sort_b orelse break :blk false;
            break :blk key.comparePart(s, a) != .lt and key.comparePart(s, b) != .gt;
        },
        .begins_with => std.mem.startsWith(u8, s.bytes, a.bytes),
    };
}

// Approximate DynamoDB item size: attribute names + value bytes.
pub fn itemBytes(item: Item) u64 {
    var total: u64 = 0;
    var it = item.attrs.iterator();
    while (it.next()) |kv| {
        total += kv.key_ptr.*.len;
        total += valueBytes(kv.value_ptr.*);
    }
    return total;
}

fn valueBytes(v: AttributeValue) u64 {
    return switch (v) {
        .S, .N, .B => |s| s.len,
        .BOOL, .NULL => 1,
        .L => |l| blk: {
            var t: u64 = 0;
            for (l) |e| t += valueBytes(e);
            break :blk t;
        },
        .M => |m| blk: {
            var t: u64 = 0;
            var it = m.iterator();
            while (it.next()) |kv| t += kv.key_ptr.*.len + valueBytes(kv.value_ptr.*);
            break :blk t;
        },
        .SS, .NS, .BS => |set| blk: {
            var t: u64 = 0;
            for (set) |e| t += e.len;
            break :blk t;
        },
    };
}

pub fn cloneItem(a: std.mem.Allocator, item: Item) !Item {
    var out: Item = .{};
    var it = item.attrs.iterator();
    while (it.next()) |kv| {
        try out.attrs.put(a, try a.dupe(u8, kv.key_ptr.*), try cloneValue(a, kv.value_ptr.*));
    }
    return out;
}

pub fn cloneValue(a: std.mem.Allocator, v: AttributeValue) !AttributeValue {
    return switch (v) {
        .S => |s| .{ .S = try a.dupe(u8, s) },
        .N => |s| .{ .N = try a.dupe(u8, s) },
        .B => |s| .{ .B = try a.dupe(u8, s) },
        .BOOL => |b| .{ .BOOL = b },
        .NULL => .NULL,
        .L => |l| blk: {
            const out = try a.alloc(AttributeValue, l.len);
            for (l, 0..) |e, i| out[i] = try cloneValue(a, e);
            break :blk .{ .L = out };
        },
        .M => |m| blk: {
            var out: std.StringArrayHashMapUnmanaged(AttributeValue) = .empty;
            var it = m.iterator();
            while (it.next()) |kv| {
                try out.put(a, try a.dupe(u8, kv.key_ptr.*), try cloneValue(a, kv.value_ptr.*));
            }
            break :blk .{ .M = out };
        },
        .SS => |set| .{ .SS = try dupeStrSlice(a, set) },
        .NS => |set| .{ .NS = try dupeStrSlice(a, set) },
        .BS => |set| .{ .BS = try dupeStrSlice(a, set) },
    };
}

fn dupeStrSlice(a: std.mem.Allocator, set: []const []const u8) ![][]const u8 {
    const out = try a.alloc([]const u8, set.len);
    for (set, 0..) |s, i| out[i] = try a.dupe(u8, s);
    return out;
}
