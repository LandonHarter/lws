const std = @import("std");
const queue = @import("queue.zig");
const config = @import("config");
const attrs = @import("attrs.zig");
const queue_dir = @import("persist/queue_dir.zig");
const message_store = @import("store/message_store.zig");
const time = @import("core").time;

pub const CooldownSeconds: i64 = 60;
pub const PurgeCooldownSeconds: i64 = 60;

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
        if (q.store) |s| s.vtable.deinit(s.ctx);
        const arena_ptr = q.arena;
        arena_ptr.deinit();
        gpa.destroy(arena_ptr);
    }

    // Allocates a MessageStore in the queue's arena, opens its WAL, and (when
    // recovering an existing queue) replays persisted state. Internal store
    // heap lives in self.gpa and is freed by Store.deinit on destroyQueue.
    fn attachStore(self: *Registry, q: *queue.Queue, dir: []const u8, recover_existing: bool) !void {
        const a = q.arena.allocator();
        const wal_path = try std.fs.path.join(a, &.{ dir, "messages.log" });
        const snap_path = try std.fs.path.join(a, &.{ dir, "snapshot.bin" });
        const sp = try a.create(message_store.Store);
        sp.* = try message_store.Store.init(self.gpa, self.io, self.clock, q, wal_path, snap_path, self.fsync);
        if (recover_existing) try sp.recover();
        q.store = .{ .ctx = sp, .vtable = &message_store.vtable };
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
        try self.attachStore(q, dir, false);
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

    // Resolves a queue from its ARN by taking the last ':'-delimited segment as
    // the queue name. Returns null for a malformed ARN or unknown queue.
    pub fn byArn(self: *Registry, arn: []const u8) ?*queue.Queue {
        const idx = std.mem.lastIndexOfScalar(u8, arn, ':') orelse return null;
        const name = arn[idx + 1 ..];
        if (name.len == 0) return null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.queues_by_name.get(name);
    }

    // Validates each (name,value) with op=.update against the queue kind, then
    // applies them all and rewrites meta.json. Validation is atomic: a single
    // bad attr aborts before any mutation.
    pub fn setAttributes(self: *Registry, name: []const u8, raw_attrs: *const queue.TagMap) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const q = self.queues_by_name.get(name) orelse return error.QueueDoesNotExist;
        q.mutex.lockUncancelable(self.io);
        defer q.mutex.unlock(self.io);

        var vit = raw_attrs.iterator();
        while (vit.next()) |e| {
            _ = try config.validateOne(&attrs.queue_attrs, .update, q.kind, e.key_ptr.*, e.value_ptr.*);
        }

        const a = q.arena.allocator();
        var ait = raw_attrs.iterator();
        while (ait.next()) |e| {
            const resolved = try config.validateOne(&attrs.queue_attrs, .update, q.kind, e.key_ptr.*, e.value_ptr.*);
            const dup = try queue.dupeValue(a, resolved);
            if (q.attributes.getPtr(e.key_ptr.*)) |slot| {
                slot.* = dup;
            } else {
                try q.attributes.put(a, try a.dupe(u8, e.key_ptr.*), dup);
            }
        }

        const now = self.clock.nowSec();
        q.last_modified_at = now;

        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const dir = try queue_dir.dirPath(sa, self.data_dir, q.id);
        try queue_dir.writeMeta(sa, self.io, dir, .{
            .queue_id = q.id,
            .name = q.name,
            .kind = q.kind,
            .attributes = q.attributes,
            .tags = q.tags,
            .created_at = q.created_at,
            .last_modified_at = now,
        }, self.fsync);
    }

    pub fn purge(self: *Registry, name: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const q = self.queues_by_name.get(name) orelse return error.QueueDoesNotExist;
        const now = self.clock.nowSec();
        if (q.last_purge_at) |last| {
            if (now - last < PurgeCooldownSeconds) return error.PurgeInProgress;
        }
        q.last_purge_at = now;
        if (q.store) |s| try s.vtable.purge(s.ctx);
    }

    // Names of queues whose RedrivePolicy.deadLetterTargetArn matches target_arn,
    // sorted, duped into gpa_out. Malformed RedrivePolicy JSON is skipped silently.
    pub fn dlqSourceNames(self: *Registry, gpa_out: std.mem.Allocator, target_arn: []const u8) ![][]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |n| gpa_out.free(n);
            out.deinit(gpa_out);
        }

        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();

        for (self.queues_by_name.keys(), self.queues_by_name.values()) |name, q| {
            const rp = q.attributes.get("RedrivePolicy") orelse continue;
            const json_str = switch (rp) {
                .json => |j| j,
                .string => |s| s,
                else => continue,
            };
            _ = scratch.reset(.retain_capacity);
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), json_str, .{}) catch continue;
            if (parsed != .object) continue;
            const arn_v = parsed.object.get("deadLetterTargetArn") orelse continue;
            if (arn_v != .string) continue;
            if (std.mem.eql(u8, arn_v.string, target_arn)) {
                try out.append(gpa_out, try gpa_out.dupe(u8, name));
            }
        }

        const slice = try out.toOwnedSlice(gpa_out);
        std.mem.sort([]const u8, slice, {}, lessThanStr);
        return slice;
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
            try self.attachStore(q, dirpath, true);
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

test "setAttributes updates value and rejects illegal" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var prng = std.Random.DefaultPrng.init(20);
    var reg = testRegistry(io, data_dir, time.Clock.fixed(1000, 0), &prng);
    defer reg.deinit();

    var raw: queue.TagMap = .empty;
    defer raw.deinit(testing.allocator);
    var tags: queue.TagMap = .empty;
    defer tags.deinit(testing.allocator);
    _ = try reg.create("x", &raw, &tags);

    var upd: queue.TagMap = .empty;
    defer upd.deinit(testing.allocator);
    try upd.put(testing.allocator, "VisibilityTimeout", "120");
    try reg.setAttributes("x", &upd);
    try testing.expectEqual(@as(i64, 120), reg.get("x").?.attributes.get("VisibilityTimeout").?.integer);

    // create-only on update -> InvalidAttributeName
    var bad_name: queue.TagMap = .empty;
    defer bad_name.deinit(testing.allocator);
    try bad_name.put(testing.allocator, "FifoQueue", "true");
    try testing.expectError(config.Error.InvalidAttributeName, reg.setAttributes("x", &bad_name));

    // out of range -> InvalidAttributeValue, and nothing applied (atomic)
    var bad_val: queue.TagMap = .empty;
    defer bad_val.deinit(testing.allocator);
    try bad_val.put(testing.allocator, "DelaySeconds", "5");
    try bad_val.put(testing.allocator, "VisibilityTimeout", "99999");
    try testing.expectError(config.Error.InvalidAttributeValue, reg.setAttributes("x", &bad_val));
    try testing.expectEqual(@as(i64, 0), reg.get("x").?.attributes.get("DelaySeconds").?.integer);
}

test "setAttributes survives recover" {
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
        var prng = std.Random.DefaultPrng.init(21);
        var reg = testRegistry(io, data_dir, time.Clock.fixed(1000, 0), &prng);
        defer reg.deinit();
        _ = try reg.create("x", &raw, &tags);
        var upd: queue.TagMap = .empty;
        defer upd.deinit(testing.allocator);
        try upd.put(testing.allocator, "VisibilityTimeout", "120");
        try reg.setAttributes("x", &upd);
    }

    var prng2 = std.Random.DefaultPrng.init(22);
    var reg2 = testRegistry(io, data_dir, time.Clock.fixed(1000, 0), &prng2);
    defer reg2.deinit();
    try reg2.recover();
    try testing.expectEqual(@as(i64, 120), reg2.get("x").?.attributes.get("VisibilityTimeout").?.integer);
}

test "purge cooldown" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var prng = std.Random.DefaultPrng.init(23);
    var reg = testRegistry(io, data_dir, time.Clock.fixed(1000, 0), &prng);
    defer reg.deinit();

    var raw: queue.TagMap = .empty;
    defer raw.deinit(testing.allocator);
    var tags: queue.TagMap = .empty;
    defer tags.deinit(testing.allocator);
    _ = try reg.create("x", &raw, &tags);

    try reg.purge("x");
    try testing.expectError(error.PurgeInProgress, reg.purge("x"));
    reg.clock = time.Clock.fixed(1000 + PurgeCooldownSeconds, 0);
    try reg.purge("x");
    try testing.expectError(error.QueueDoesNotExist, reg.purge("nope"));
}

test "dlqSourceNames matches RedrivePolicy target" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var prng = std.Random.DefaultPrng.init(24);
    var reg = testRegistry(io, data_dir, time.Clock.fixed(1000, 0), &prng);
    defer reg.deinit();

    var tags: queue.TagMap = .empty;
    defer tags.deinit(testing.allocator);

    var dlq_raw: queue.TagMap = .empty;
    defer dlq_raw.deinit(testing.allocator);
    _ = try reg.create("dlq", &dlq_raw, &tags);

    var a_raw: queue.TagMap = .empty;
    defer a_raw.deinit(testing.allocator);
    try a_raw.put(testing.allocator, "RedrivePolicy", "{\"deadLetterTargetArn\":\"arn:aws:sqs:us-east-1:000000000000:dlq\",\"maxReceiveCount\":5}");
    _ = try reg.create("srcA", &a_raw, &tags);

    // malformed RedrivePolicy is skipped, not an error
    var b_raw: queue.TagMap = .empty;
    defer b_raw.deinit(testing.allocator);
    try b_raw.put(testing.allocator, "RedrivePolicy", "not json");
    _ = try reg.create("srcB", &b_raw, &tags);

    const names = try reg.dlqSourceNames(testing.allocator, "arn:aws:sqs:us-east-1:000000000000:dlq");
    defer {
        for (names) |n| testing.allocator.free(n);
        testing.allocator.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("srcA", names[0]);
}
