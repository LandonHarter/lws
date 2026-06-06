const std = @import("std");
const queue = @import("queue.zig");
const config = @import("config");
const queue_dir = @import("persist/queue_dir.zig");
const time = @import("core").time;

pub const CooldownSeconds: i64 = 60;

pub const Registry = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    fsync: bool,
    clock: time.Clock,
    rng: std.Random,
    queues_by_name: std.StringArrayHashMapUnmanaged(*queue.Queue) = .empty,
    tombstones: std.StringArrayHashMapUnmanaged(i64) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, fsync: bool, clock: time.Clock, rng: std.Random) Registry {
        return .{ .gpa = gpa, .io = io, .data_dir = data_dir, .fsync = fsync, .clock = clock, .rng = rng };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.queues_by_name.iterator();
        while (it.next()) |e| destroyQueue(self.gpa, e.value_ptr.*);
        self.queues_by_name.deinit(self.gpa);
        var tit = self.tombstones.iterator();
        while (tit.next()) |e| self.gpa.free(e.key_ptr.*);
        self.tombstones.deinit(self.gpa);
    }

    fn destroyQueue(gpa: std.mem.Allocator, q: *queue.Queue) void {
        const arena_ptr = q.arena;
        arena_ptr.deinit();
        gpa.destroy(arena_ptr);
    }

    pub fn create(self: *Registry, name: []const u8, raw_attrs: *const queue.TagMap, tags: *const queue.TagMap) !*queue.Queue {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const kind = queue.deriveKind(raw_attrs);
        try queue.validateName(name, kind);

        const arena_ptr = try self.gpa.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.gpa);
        var keep = false;
        defer if (!keep) {
            arena_ptr.deinit();
            self.gpa.destroy(arena_ptr);
        };
        const a = arena_ptr.allocator();

        const attributes = try queue.buildAttributes(a, raw_attrs, kind);

        if (self.queues_by_name.get(name)) |existing| {
            if (queue.attributesEql(&existing.attributes, &attributes)) return existing;
            return error.QueueNameExists;
        }

        const now = self.clock.nowSec();
        if (self.tombstones.get(name)) |deleted_at| {
            if (now - deleted_at < CooldownSeconds) return error.QueueDeletedRecently;
            self.purgeTombstone(name);
        }

        var id: [16]u8 = undefined;
        self.rng.bytes(&id);

        var tags_dup: queue.TagMap = .empty;
        var tit = tags.iterator();
        while (tit.next()) |e| {
            try tags_dup.put(a, try a.dupe(u8, e.key_ptr.*), try a.dupe(u8, e.value_ptr.*));
        }

        const name_dup = try a.dupe(u8, name);

        const dir = try queue_dir.ensureDir(a, self.io, self.data_dir, id);
        try queue_dir.writeMeta(a, self.io, dir, .{
            .queue_id = id,
            .name = name_dup,
            .kind = kind,
            .attributes = attributes,
            .tags = tags_dup,
            .created_at = now,
            .last_modified_at = now,
        }, self.fsync);

        const q = try a.create(queue.Queue);
        q.* = .{
            .id = id,
            .name = name_dup,
            .kind = kind,
            .attributes = attributes,
            .tags = tags_dup,
            .created_at = now,
            .last_modified_at = now,
            .arena = arena_ptr,
        };

        try self.queues_by_name.put(self.gpa, name_dup, q);
        keep = true;
        return q;
    }

    pub fn delete(self: *Registry, name: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const idx = self.queues_by_name.getIndex(name) orelse return error.QueueDoesNotExist;
        const q = self.queues_by_name.values()[idx];

        const now = self.clock.nowSec();
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const dir = try queue_dir.dirPath(sa, self.data_dir, q.id);
        queue_dir.markDeleted(sa, self.io, dir, now, self.fsync) catch {};

        const key = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(key);
        try self.tombstones.put(self.gpa, key, now);

        self.queues_by_name.orderedRemoveAt(idx);
        destroyQueue(self.gpa, q);
    }

    fn purgeTombstone(self: *Registry, name: []const u8) void {
        if (self.tombstones.fetchOrderedRemove(name)) |kv| {
            self.gpa.free(kv.key);
        }
    }

    pub fn get(self: *Registry, name: []const u8) ?*queue.Queue {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.queues_by_name.get(name);
    }

    // Returns sorted names matching `prefix`, duped into `gpa_out`.
    pub fn listNames(self: *Registry, gpa_out: std.mem.Allocator, prefix: ?[]const u8) ![][]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |n| gpa_out.free(n);
            out.deinit(gpa_out);
        }
        for (self.queues_by_name.keys()) |name| {
            if (prefix) |p| if (!std.mem.startsWith(u8, name, p)) continue;
            try out.append(gpa_out, try gpa_out.dupe(u8, name));
        }
        const slice = try out.toOwnedSlice(gpa_out);
        std.mem.sort([]const u8, slice, {}, lessThanStr);
        return slice;
    }

    fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    pub fn recover(self: *Registry) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const root = try queue_dir.queuesRoot(sa, self.data_dir);
        var dir = std.Io.Dir.cwd().openDir(self.io, root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            const dirpath = try std.fs.path.join(sa, &.{ root, entry.name });

            const del = try queue_dir.readDeleted(sa, self.io, dirpath);
            if (del) |deleted_at| {
                const now = self.clock.nowSec();
                if (now - deleted_at < CooldownSeconds) {
                    const meta = queue_dir.readMeta(sa, self.io, dirpath) catch continue;
                    try self.tombstones.put(self.gpa, try self.gpa.dupe(u8, meta.name), deleted_at);
                } else {
                    std.Io.Dir.cwd().deleteTree(self.io, dirpath) catch {};
                }
                continue;
            }

            const arena_ptr = try self.gpa.create(std.heap.ArenaAllocator);
            arena_ptr.* = std.heap.ArenaAllocator.init(self.gpa);
            const a = arena_ptr.allocator();
            const meta = queue_dir.readMeta(a, self.io, dirpath) catch {
                arena_ptr.deinit();
                self.gpa.destroy(arena_ptr);
                continue;
            };
            const q = try a.create(queue.Queue);
            q.* = .{
                .id = meta.queue_id,
                .name = meta.name,
                .kind = meta.kind,
                .attributes = meta.attributes,
                .tags = meta.tags,
                .created_at = meta.created_at,
                .last_modified_at = meta.last_modified_at,
                .arena = arena_ptr,
            };
            try self.queues_by_name.put(self.gpa, meta.name, q);
        }
    }
};

const testing = std.testing;

fn testRegistry(io: std.Io, data_dir: []const u8, clock: time.Clock, prng: *std.Random.DefaultPrng) Registry {
    return Registry.init(testing.allocator, io, data_dir, false, clock, prng.random());
}

// Unique per-process dir so the same test running concurrently in multiple
// test binaries (registry root + wire_test transitive root) never collides.
fn tmpDataDir(buf: []u8, tmp: *const std.testing.TmpDir) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
}

test "create then get returns pointer" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var prng = std.Random.DefaultPrng.init(1);
    var reg = testRegistry(io, data_dir, time.Clock.fixed(1000, 0), &prng);
    defer reg.deinit();

    var raw: queue.TagMap = .empty;
    defer raw.deinit(testing.allocator);
    var tags: queue.TagMap = .empty;
    defer tags.deinit(testing.allocator);

    const q = try reg.create("x", &raw, &tags);
    try testing.expectEqualStrings("x", q.name);
    try testing.expect(reg.get("x") == q);
    try testing.expect(reg.get("nope") == null);
}

test "create idempotent same attrs returns same pointer" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var prng = std.Random.DefaultPrng.init(2);
    var reg = testRegistry(io, data_dir, time.Clock.fixed(1000, 0), &prng);
    defer reg.deinit();

    var raw: queue.TagMap = .empty;
    defer raw.deinit(testing.allocator);
    try raw.put(testing.allocator, "VisibilityTimeout", "60");
    var tags: queue.TagMap = .empty;
    defer tags.deinit(testing.allocator);

    const a = try reg.create("x", &raw, &tags);
    const b = try reg.create("x", &raw, &tags);
    try testing.expect(a == b);
}

test "create same name different attrs errors" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var prng = std.Random.DefaultPrng.init(3);
    var reg = testRegistry(io, data_dir, time.Clock.fixed(1000, 0), &prng);
    defer reg.deinit();

    var raw1: queue.TagMap = .empty;
    defer raw1.deinit(testing.allocator);
    try raw1.put(testing.allocator, "VisibilityTimeout", "60");
    var raw2: queue.TagMap = .empty;
    defer raw2.deinit(testing.allocator);
    try raw2.put(testing.allocator, "VisibilityTimeout", "30");
    var tags: queue.TagMap = .empty;
    defer tags.deinit(testing.allocator);

    _ = try reg.create("x", &raw1, &tags);
    try testing.expectError(error.QueueNameExists, reg.create("x", &raw2, &tags));
}

test "delete then create within cooldown rejected, allowed after" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var prng = std.Random.DefaultPrng.init(4);
    var reg = testRegistry(io, data_dir, time.Clock.fixed(1000, 0), &prng);
    defer reg.deinit();

    var raw: queue.TagMap = .empty;
    defer raw.deinit(testing.allocator);
    var tags: queue.TagMap = .empty;
    defer tags.deinit(testing.allocator);

    _ = try reg.create("x", &raw, &tags);
    try reg.delete("x");
    try testing.expectError(error.QueueDeletedRecently, reg.create("x", &raw, &tags));

    reg.clock = time.Clock.fixed(1000 + CooldownSeconds, 0);
    const q = try reg.create("x", &raw, &tags);
    try testing.expectEqualStrings("x", q.name);
}

test "delete missing returns QueueDoesNotExist" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var prng = std.Random.DefaultPrng.init(5);
    var reg = testRegistry(io, data_dir, time.Clock.fixed(1000, 0), &prng);
    defer reg.deinit();
    try testing.expectError(error.QueueDoesNotExist, reg.delete("nope"));
}

test "recover rebuilds queues from disk" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var raw: queue.TagMap = .empty;
    defer raw.deinit(testing.allocator);
    var tags: queue.TagMap = .empty;
    defer tags.deinit(testing.allocator);

    {
        var prng = std.Random.DefaultPrng.init(6);
        var reg = testRegistry(io, data_dir, time.Clock.fixed(1000, 0), &prng);
        defer reg.deinit();
        _ = try reg.create("a", &raw, &tags);
        _ = try reg.create("b", &raw, &tags);
        try reg.delete("b");
    }

    var prng2 = std.Random.DefaultPrng.init(7);
    var reg2 = testRegistry(io, data_dir, time.Clock.fixed(1000, 0), &prng2);
    defer reg2.deinit();
    try reg2.recover();
    try testing.expect(reg2.get("a") != null);
    try testing.expect(reg2.get("b") == null);
    try testing.expectError(error.QueueDeletedRecently, reg2.create("b", &raw, &tags));
}

test "listNames sorted and prefix filtered" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var prng = std.Random.DefaultPrng.init(8);
    var reg = testRegistry(io, data_dir, time.Clock.fixed(1000, 0), &prng);
    defer reg.deinit();

    var raw: queue.TagMap = .empty;
    defer raw.deinit(testing.allocator);
    var tags: queue.TagMap = .empty;
    defer tags.deinit(testing.allocator);

    _ = try reg.create("foo", &raw, &tags);
    _ = try reg.create("bar", &raw, &tags);
    _ = try reg.create("food", &raw, &tags);

    const all = try reg.listNames(testing.allocator, null);
    defer {
        for (all) |n| testing.allocator.free(n);
        testing.allocator.free(all);
    }
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqualStrings("bar", all[0]);
    try testing.expectEqualStrings("foo", all[1]);
    try testing.expectEqualStrings("food", all[2]);

    const fo = try reg.listNames(testing.allocator, "fo");
    defer {
        for (fo) |n| testing.allocator.free(n);
        testing.allocator.free(fo);
    }
    try testing.expectEqual(@as(usize, 2), fo.len);
}
