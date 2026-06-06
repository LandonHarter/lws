const std = @import("std");
const time = @import("core").time;
const bucket_dir = @import("persist/bucket_dir.zig");
const object_dir = @import("persist/object_dir.zig");
const upload_dir = @import("persist/upload_dir.zig");
const object_store = @import("store/object_store.zig");
const multipart = @import("store/multipart.zig");

pub const Bucket = struct {
    arena: *std.heap.ArenaAllocator,
    name: []const u8,
    region: []const u8,
    created_at: i64,
    dir: []const u8, // on-disk bucket base dir
    mutex: std.Io.Mutex = .init,
    object_index: object_store.ObjectIndex,
    upload_index: multipart.UploadIndex,

    // Rebuilds the in-memory key index from objects/ on disk. A dir whose
    // meta.json is missing/corrupt, or whose data size disagrees with meta, is
    // a half-written record and is skipped.
    fn recoverObjects(self: *Bucket, io: std.Io) !void {
        const a = self.arena.allocator();
        const root = try object_dir.objectsRoot(a, self.dir);
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            const obj_dir = try std.fs.path.join(a, &.{ root, entry.name });
            const meta = object_dir.readMeta(a, io, obj_dir) catch continue;
            const size = object_dir.dataSize(a, io, obj_dir) catch continue;
            if (size != meta.size) continue;
            try self.object_index.put(meta);
        }
    }

    // Rebuilds in-flight multipart uploads from uploads/ on disk. A part whose
    // file is missing or whose size disagrees with the manifest is dropped so a
    // re-uploaded part overwrites it.
    fn recoverUploads(self: *Bucket, io: std.Io) !void {
        const a = self.arena.allocator();
        const root = try upload_dir.uploadsRoot(a, self.dir);
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            const base = try std.fs.path.join(a, &.{ root, entry.name });
            const parsed = upload_dir.readMeta(a, io, base) catch continue;
            const u = self.upload_index.create(parsed.upload_id, parsed.key, parsed.content_type, parsed.initiated_at_ms) catch continue;
            var umit = parsed.user_meta.iterator();
            while (umit.next()) |e| u.putUserMeta(e.key_ptr.*, e.value_ptr.*) catch {};
            for (parsed.parts) |p| {
                const pp = upload_dir.partPath(a, base, p.n) catch continue;
                const st = std.Io.Dir.cwd().statFile(io, pp, .{}) catch continue;
                if (st.size != p.size) continue;
                u.putPart(p) catch {};
            }
        }
    }
};

pub const BucketStat = struct {
    name: []const u8,
    objects: u64,
    bytes: u64,
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    fsync: bool,
    clock: time.Clock,
    rng: std.Random,
    buckets_by_name: std.StringArrayHashMapUnmanaged(*Bucket) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, fsync: bool, clock: time.Clock, rng: std.Random) Registry {
        return .{ .gpa = gpa, .io = io, .data_dir = data_dir, .fsync = fsync, .clock = clock, .rng = rng };
    }

    pub fn deinit(self: *Registry) void {
        for (self.buckets_by_name.values()) |b| destroyBucket(self.gpa, b);
        self.buckets_by_name.deinit(self.gpa);
    }

    fn destroyBucket(gpa: std.mem.Allocator, b: *Bucket) void {
        b.upload_index.deinit();
        const arena_ptr = b.arena;
        arena_ptr.deinit();
        gpa.destroy(arena_ptr);
    }

    // Builds a Bucket struct (arena, indexes) without touching disk. Caller owns
    // disk creation/recovery and map insertion.
    fn buildBucket(self: *Registry, name: []const u8, region: []const u8, created_at: i64, dir: []const u8) !*Bucket {
        const arena_ptr = try self.gpa.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.gpa);
        errdefer {
            arena_ptr.deinit();
            self.gpa.destroy(arena_ptr);
        }
        const a = arena_ptr.allocator();
        const b = try a.create(Bucket);
        b.* = .{
            .arena = arena_ptr,
            .name = try a.dupe(u8, name),
            .region = try a.dupe(u8, region),
            .created_at = created_at,
            .dir = try a.dupe(u8, dir),
            .object_index = object_store.ObjectIndex.init(a),
            .upload_index = multipart.UploadIndex.init(self.gpa),
        };
        return b;
    }

    pub fn create(self: *Registry, name: []const u8, region: []const u8) !*Bucket {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try bucket_dir.validateName(name);
        if (self.buckets_by_name.get(name)) |existing| return existing;

        const now = self.clock.nowSec();
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const dir = try bucket_dir.ensureDirs(sa, self.io, self.data_dir, name);
        try bucket_dir.writeMeta(sa, self.io, dir, .{ .name = name, .region = region, .created_at = now }, self.fsync);

        const b = try self.buildBucket(name, region, now, dir);
        errdefer destroyBucket(self.gpa, b);
        try self.buckets_by_name.put(self.gpa, b.name, b);
        return b;
    }

    pub fn get(self: *Registry, name: []const u8) ?*Bucket {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.buckets_by_name.get(name);
    }

    // Removes an empty bucket from memory and disk. Errors with NoSuchBucket if
    // missing, BucketNotEmpty if it still holds objects.
    pub fn delete(self: *Registry, name: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const idx = self.buckets_by_name.getIndex(name) orelse return error.NoSuchBucket;
        const b = self.buckets_by_name.values()[idx];
        if (b.object_index.count() > 0) return error.BucketNotEmpty;

        std.Io.Dir.cwd().deleteTree(self.io, b.dir) catch {};
        self.buckets_by_name.orderedRemoveAt(idx);
        destroyBucket(self.gpa, b);
    }

    // Sorted bucket names, duped into `out`.
    pub fn listNames(self: *Registry, out: std.mem.Allocator) ![]const []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const slice = try out.alloc([]const u8, self.buckets_by_name.count());
        for (self.buckets_by_name.keys(), 0..) |name, i| slice[i] = try out.dupe(u8, name);
        std.mem.sort([]const u8, slice, {}, lessThanStr);
        return slice;
    }

    fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    // Per-bucket object/byte counts, sorted by name, duped into `out`.
    pub fn stats(self: *Registry, out: std.mem.Allocator) ![]BucketStat {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const slice = try out.alloc(BucketStat, self.buckets_by_name.count());
        for (self.buckets_by_name.values(), 0..) |b, i| {
            b.mutex.lockUncancelable(self.io);
            defer b.mutex.unlock(self.io);
            slice[i] = .{
                .name = try out.dupe(u8, b.name),
                .objects = b.object_index.count(),
                .bytes = b.object_index.totalBytes(),
            };
        }
        std.mem.sort(BucketStat, slice, {}, lessThanStat);
        return slice;
    }

    fn lessThanStat(_: void, a: BucketStat, b: BucketStat) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }

    pub fn recover(self: *Registry) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const root = try bucket_dir.bucketsRoot(sa, self.data_dir);
        var dir = std.Io.Dir.cwd().openDir(self.io, root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            // Safety net: a dir whose name isn't a legal bucket name is tampering.
            bucket_dir.validateName(entry.name) catch continue;
            const dirpath = try std.fs.path.join(sa, &.{ root, entry.name });
            const meta = bucket_dir.readMeta(sa, self.io, dirpath) catch continue;

            const b = try self.buildBucket(meta.name, meta.region, meta.created_at, dirpath);
            errdefer destroyBucket(self.gpa, b);
            try b.recoverObjects(self.io);
            try b.recoverUploads(self.io);
            try self.buckets_by_name.put(self.gpa, b.name, b);
        }
    }
};

const testing = std.testing;

fn tmpDataDir(buf: []u8, tmp: *const std.testing.TmpDir) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
}

fn testRegistry(io: std.Io, data_dir: []const u8, prng: *std.Random.DefaultPrng) Registry {
    return Registry.init(testing.allocator, io, data_dir, false, time.Clock.fixed(1717689600, 0), prng.random());
}

test "create then get; idempotent; invalid name rejected" {
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

    const b = try reg.create("test-bucket", "us-east-1");
    try testing.expectEqualStrings("test-bucket", b.name);
    try testing.expect(reg.get("test-bucket") == b);
    try testing.expect(reg.create("test-bucket", "us-east-1") catch unreachable == b);
    try testing.expect(reg.get("nope") == null);
    try testing.expectError(error.InvalidBucketName, reg.create("Bad_Name", "us-east-1"));
}

test "delete empty ok, non-empty rejected, missing errors" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var prng = std.Random.DefaultPrng.init(2);
    var reg = testRegistry(io, data_dir, &prng);
    defer reg.deinit();

    const b = try reg.create("buck", "us-east-1");
    try testing.expectError(error.NoSuchBucket, reg.delete("nope"));

    // Add an object to the index -> not empty.
    const um: object_store.UserMeta = .empty;
    try b.object_index.put(.{ .key = "k", .etag = ("0" ** 32).*, .size = 1, .content_type = "x", .user_meta = um, .last_modified_ms = 0 });
    try testing.expectError(error.BucketNotEmpty, reg.delete("buck"));

    _ = b.object_index.remove("k");
    try reg.delete("buck");
    try testing.expect(reg.get("buck") == null);
}

test "listNames + stats sorted" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    var prng = std.Random.DefaultPrng.init(3);
    var reg = testRegistry(io, data_dir, &prng);
    defer reg.deinit();

    _ = try reg.create("foo", "us-east-1");
    const bar = try reg.create("bar", "us-east-1");
    const um: object_store.UserMeta = .empty;
    try bar.object_index.put(.{ .key = "k", .etag = ("0" ** 32).*, .size = 7, .content_type = "x", .user_meta = um, .last_modified_ms = 0 });

    const names = try reg.listNames(testing.allocator);
    defer {
        for (names) |n| testing.allocator.free(n);
        testing.allocator.free(names);
    }
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("bar", names[0]);
    try testing.expectEqualStrings("foo", names[1]);

    const st = try reg.stats(testing.allocator);
    defer {
        for (st) |s| testing.allocator.free(s.name);
        testing.allocator.free(st);
    }
    try testing.expectEqualStrings("bar", st[0].name);
    try testing.expectEqual(@as(u64, 1), st[0].objects);
    try testing.expectEqual(@as(u64, 7), st[0].bytes);
    try testing.expectEqual(@as(u64, 0), st[1].objects);
}

test "recover rebuilds buckets, objects, and uploads" {
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

        const b = try reg.create("data-bucket", "us-west-2");
        const a = b.arena.allocator();

        // Persist one object on disk.
        const odir = try object_dir.ensureDir(a, io, b.dir, "logs/x.txt");
        try object_dir.writeData(a, io, odir, "hello", false);
        var um: object_store.UserMeta = .empty;
        try um.put(a, "foo", "bar");
        try object_dir.writeMeta(a, io, odir, .{
            .key = "logs/x.txt",
            .etag = ("a" ** 32).*,
            .size = 5,
            .content_type = "text/plain",
            .user_meta = um,
            .last_modified_ms = 0,
        }, false);

        // Persist one in-flight upload with a part.
        const uid = "8fd13a1c-7c8e-4f1e-8e3a-99b4f2e0a1d2";
        const ubase = try upload_dir.ensureDir(a, io, b.dir, uid);
        try upload_dir.writePart(a, io, ubase, 1, "PARTBYTES!", false);
        var uidarr: [36]u8 = undefined;
        @memcpy(&uidarr, uid);
        const u = try b.upload_index.create(uidarr, "big", "application/octet-stream", 0);
        const md5 = @import("core").md5;
        var etag: [32]u8 = undefined;
        md5.hexLower(&etag, "PARTBYTES!");
        try u.putPart(.{ .n = 1, .etag = etag, .size = 10 });
        try upload_dir.writeMeta(a, io, ubase, u, false);
    }

    var prng2 = std.Random.DefaultPrng.init(5);
    var reg2 = testRegistry(io, data_dir, &prng2);
    defer reg2.deinit();
    try reg2.recover();

    const b = reg2.get("data-bucket") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("us-west-2", b.region);
    try testing.expectEqual(@as(usize, 1), b.object_index.count());
    try testing.expectEqual(@as(u64, 5), b.object_index.get("logs/x.txt").?.size);
    try testing.expectEqual(@as(usize, 1), b.upload_index.count());
    const u = b.upload_index.get("8fd13a1c-7c8e-4f1e-8e3a-99b4f2e0a1d2").?;
    try testing.expectEqual(@as(usize, 1), u.parts.items.len);
}

test "recover skips object dir whose data size mismatches meta" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    {
        var prng = std.Random.DefaultPrng.init(6);
        var reg = testRegistry(io, data_dir, &prng);
        defer reg.deinit();
        const b = try reg.create("buck", "us-east-1");
        const a = b.arena.allocator();
        const odir = try object_dir.ensureDir(a, io, b.dir, "k");
        try object_dir.writeData(a, io, odir, "abc", false); // 3 bytes on disk
        const um: object_store.UserMeta = .empty;
        try object_dir.writeMeta(a, io, odir, .{
            .key = "k",
            .etag = ("a" ** 32).*,
            .size = 999, // claims 999 -> mismatch
            .content_type = "x",
            .user_meta = um,
            .last_modified_ms = 0,
        }, false);
    }

    var prng2 = std.Random.DefaultPrng.init(7);
    var reg2 = testRegistry(io, data_dir, &prng2);
    defer reg2.deinit();
    try reg2.recover();
    const b = reg2.get("buck").?;
    try testing.expectEqual(@as(usize, 0), b.object_index.count());
}

test "recover skips dirs that fail bucket name validation" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [64]u8 = undefined;
    const data_dir = tmpDataDir(&dbuf, &tmp);

    // Hand-create an illegally-named dir under buckets/.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bad = try std.fs.path.join(a, &.{ data_dir, "buckets", "Bad_Name" });
    try std.Io.Dir.createDirPath(.cwd(), io, bad);

    var prng = std.Random.DefaultPrng.init(8);
    var reg = testRegistry(io, data_dir, &prng);
    defer reg.deinit();
    try reg.recover();
    try testing.expectEqual(@as(usize, 0), reg.buckets_by_name.count());
}
