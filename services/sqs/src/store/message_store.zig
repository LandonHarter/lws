const std = @import("std");
const message = @import("../message.zig");
const receipt = @import("../receipt.zig");
const queue = @import("../queue.zig");
const config = @import("config");
const time_mod = @import("core").time;
const wal = @import("wal.zig");

const Order = std.math.Order;

fn cmpSeq(_: void, a: *message.Message, b: *message.Message) Order {
    return std.math.order(a.seq, b.seq);
}
fn cmpDelay(_: void, a: *message.Message, b: *message.Message) Order {
    return std.math.order(a.delay_until_ms, b.delay_until_ms);
}

const VisibleQ = std.PriorityQueue(*message.Message, void, cmpSeq);
const DelayedQ = std.PriorityQueue(*message.Message, void, cmpDelay);

const snapshot_magic: u32 = 0x53515331; // 'SQS1'
const snapshot_threshold: u32 = 10_000;

pub const ReceivedMessage = struct {
    msg: *message.Message,
    receipt_handle: []const u8,
};

pub const InflightEntry = struct {
    msg: *message.Message,
    visible_at_ms: i64,
    lease_nonce: u64,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: time_mod.Clock,
    queue: *queue.Queue,
    wal_path: []const u8,
    snapshot_path: []const u8,

    mutex: std.Io.Mutex = .init,
    wait: std.Io.Condition = .init, // Plan 07 signals here

    visible: VisibleQ = .empty,
    delayed: DelayedQ = .empty,
    inflight: std.AutoArrayHashMapUnmanaged(u64, InflightEntry) = .empty,

    next_seq: u64 = 1,
    next_nonce: u64 = 1,
    wal: wal.WalWriter,
    snapshot_pending_writes: u32 = 0,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        clock: time_mod.Clock,
        q: *queue.Queue,
        wal_path: []const u8,
        snapshot_path: []const u8,
        fsync: bool,
    ) !Store {
        const w = try wal.WalWriter.open(io, wal_path, fsync);
        return .{
            .gpa = gpa,
            .io = io,
            .clock = clock,
            .queue = q,
            .wal_path = wal_path,
            .snapshot_path = snapshot_path,
            .wal = w,
        };
    }

    pub fn deinit(self: *Store) void {
        while (self.visible.pop()) |m| m.destroy(self.gpa);
        while (self.delayed.pop()) |m| m.destroy(self.gpa);
        for (self.inflight.values()) |e| e.msg.destroy(self.gpa);
        self.visible.deinit(self.gpa);
        self.delayed.deinit(self.gpa);
        self.inflight.deinit(self.gpa);
        self.wal.close();
    }

    // ---- retention ----

    fn retentionMs(self: *Store) i64 {
        const v = self.queue.attributes.get("MessageRetentionPeriod") orelse return 345_600_000;
        return switch (v) {
            .integer => |n| n * 1000,
            else => 345_600_000,
        };
    }

    // ---- send ----

    // Takes ownership of `msg` (allocated from self.gpa). Assigns seq, persists,
    // enqueues into visible or delayed based on delay_until_ms.
    pub fn send(self: *Store, msg: *message.Message) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        msg.seq = self.next_seq;
        self.next_seq += 1;

        try self.appendSend(msg);
        try self.enqueue(msg);
        self.afterWrite();
        self.wait.signal(self.io);
    }

    fn enqueue(self: *Store, msg: *message.Message) !void {
        const now = self.clock.nowMs();
        if (msg.delay_until_ms > now) {
            try self.delayed.push(self.gpa, msg);
        } else {
            try self.visible.push(self.gpa, msg);
        }
    }

    // ---- receive ----

    pub fn receive(self: *Store, arena: std.mem.Allocator, max: u32, visibility_ms: i64, now_ms: i64) ![]ReceivedMessage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.ArrayList(ReceivedMessage) = .empty;
        var taken: u32 = 0;
        while (taken < max) : (taken += 1) {
            const msg = self.visible.pop() orelse break;
            msg.receive_count += 1;
            if (msg.first_received_at_ms == null) msg.first_received_at_ms = now_ms;
            const nonce = self.next_nonce;
            self.next_nonce += 1;
            const visible_at = now_ms + visibility_ms;
            try self.inflight.put(self.gpa, msg.seq, .{
                .msg = msg,
                .visible_at_ms = visible_at,
                .lease_nonce = nonce,
            });
            try self.appendLease(msg.seq, nonce, visible_at);
            const handle = try receipt.encode(arena, .{
                .queue_id = self.queue.id,
                .msg_seq = msg.seq,
                .lease_nonce = nonce,
                .visible_at_ms = visible_at,
            });
            try out.append(arena, .{ .msg = msg, .receipt_handle = handle });
        }
        if (taken > 0) self.afterWrite();
        return out.toOwnedSlice(arena);
    }

    // ---- delete ----

    pub fn deleteLease(self: *Store, msg_seq: u64, nonce: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const entry = self.inflight.get(msg_seq) orelse return; // already gone: no-op success
        if (entry.lease_nonce != nonce) return; // stale handle: no-op success
        _ = self.inflight.swapRemove(msg_seq);
        try self.appendDeleteLease(msg_seq, nonce);
        self.afterWrite();
        entry.msg.destroy(self.gpa);
    }

    // ---- change visibility (used by Plan 06) ----

    pub fn changeVisibility(self: *Store, msg_seq: u64, nonce: u64, new_visible_at_ms: i64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const entry = self.inflight.getPtr(msg_seq) orelse return error.MessageNotInflight;
        if (entry.lease_nonce != nonce) return error.MessageNotInflight;
        entry.visible_at_ms = new_visible_at_ms;
        try self.appendChangeVis(msg_seq, nonce, new_visible_at_ms);
        self.afterWrite();
    }

    // ---- ticker ----

    pub fn tick(self: *Store, now_ms: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var promoted = false;

        // delayed -> visible
        while (self.delayed.peek()) |head| {
            if (head.delay_until_ms > now_ms) break;
            const m = self.delayed.pop().?;
            self.visible.push(self.gpa, m) catch {
                self.delayed.push(self.gpa, m) catch {};
                break;
            };
            promoted = true;
        }

        // inflight -> visible (lease expiry)
        var i: usize = 0;
        while (i < self.inflight.count()) {
            const entry = self.inflight.values()[i];
            if (entry.visible_at_ms <= now_ms) {
                _ = self.inflight.swapRemoveAt(i);
                self.visible.push(self.gpa, entry.msg) catch continue;
                self.appendExpireLease(entry.msg.seq, entry.lease_nonce) catch {};
                promoted = true;
            } else {
                i += 1;
            }
        }

        self.dropRetention(now_ms);

        if (promoted) {
            self.afterWriteLocked();
            self.wait.signal(self.io);
        }
    }

    fn dropRetention(self: *Store, now_ms: i64) void {
        const retention = self.retentionMs();

        // visible head is the lowest seq (oldest sent).
        while (self.visible.peek()) |head| {
            if (now_ms - head.sent_at_ms <= retention) break;
            const m = self.visible.pop().?;
            self.appendDropRetention(m.seq) catch {};
            m.destroy(self.gpa);
        }
        // delayed + inflight: scan (rare).
        var di: usize = 0;
        while (di < self.delayed.items.len) {
            const m = self.delayed.items[di];
            if (now_ms - m.sent_at_ms > retention) {
                _ = self.delayed.popIndex(di);
                self.appendDropRetention(m.seq) catch {};
                m.destroy(self.gpa);
            } else di += 1;
        }
        var fi: usize = 0;
        while (fi < self.inflight.count()) {
            const entry = self.inflight.values()[fi];
            if (now_ms - entry.msg.sent_at_ms > retention) {
                _ = self.inflight.swapRemoveAt(fi);
                self.appendDropRetention(entry.msg.seq) catch {};
                entry.msg.destroy(self.gpa);
            } else fi += 1;
        }
    }

    // ---- purge / counts ----

    pub fn purge(self: *Store) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.visible.pop()) |m| m.destroy(self.gpa);
        while (self.delayed.pop()) |m| m.destroy(self.gpa);
        for (self.inflight.values()) |e| e.msg.destroy(self.gpa);
        self.inflight.clearRetainingCapacity();
        try self.wal.append(.purge, &.{});
        self.afterWrite();
    }

    pub fn countVisible(self: *Store) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return @intCast(self.visible.count());
    }
    pub fn countInFlight(self: *Store) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return @intCast(self.inflight.count());
    }
    pub fn countDelayed(self: *Store) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return @intCast(self.delayed.count());
    }

    // ---- snapshot bookkeeping ----

    fn afterWrite(self: *Store) void {
        self.afterWriteLocked();
    }

    fn afterWriteLocked(self: *Store) void {
        self.snapshot_pending_writes += 1;
        if (self.snapshot_pending_writes >= snapshot_threshold) {
            self.writeSnapshot() catch return;
            self.wal.truncate() catch return;
            self.snapshot_pending_writes = 0;
        }
    }

    // ---- WAL payload encoders (caller holds mutex) ----

    fn appendSend(self: *Store, msg: *message.Message) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        try encodeMessageCore(self.gpa, &buf, msg);
        try self.wal.append(.send, buf.items);
    }

    fn appendLease(self: *Store, seq: u64, nonce: u64, visible_at_ms: i64) !void {
        var p: [24]u8 = undefined;
        std.mem.writeInt(u64, p[0..8], seq, .little);
        std.mem.writeInt(u64, p[8..16], nonce, .little);
        std.mem.writeInt(i64, p[16..24], visible_at_ms, .little);
        try self.wal.append(.lease, &p);
    }

    fn appendDeleteLease(self: *Store, seq: u64, nonce: u64) !void {
        var p: [16]u8 = undefined;
        std.mem.writeInt(u64, p[0..8], seq, .little);
        std.mem.writeInt(u64, p[8..16], nonce, .little);
        try self.wal.append(.delete_lease, &p);
    }

    fn appendExpireLease(self: *Store, seq: u64, nonce: u64) !void {
        var p: [16]u8 = undefined;
        std.mem.writeInt(u64, p[0..8], seq, .little);
        std.mem.writeInt(u64, p[8..16], nonce, .little);
        try self.wal.append(.expire_lease, &p);
    }

    fn appendChangeVis(self: *Store, seq: u64, nonce: u64, visible_at_ms: i64) !void {
        var p: [24]u8 = undefined;
        std.mem.writeInt(u64, p[0..8], seq, .little);
        std.mem.writeInt(u64, p[8..16], nonce, .little);
        std.mem.writeInt(i64, p[16..24], visible_at_ms, .little);
        try self.wal.append(.change_vis, &p);
    }

    fn appendDropRetention(self: *Store, seq: u64) !void {
        var p: [8]u8 = undefined;
        std.mem.writeInt(u64, &p, seq, .little);
        try self.wal.append(.drop_retention, &p);
    }

    // ---- snapshot ----

    fn writeSnapshot(self: *Store) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);

        try appendU32(self.gpa, &buf, snapshot_magic);
        try appendU64(self.gpa, &buf, self.next_seq);
        try appendU64(self.gpa, &buf, self.next_nonce);

        const total: u32 = @intCast(self.visible.count() + self.delayed.count() + self.inflight.count());
        try appendU32(self.gpa, &buf, total);

        for (self.visible.items) |m| try self.appendSnapshotMsg(&buf, m, false, 0, 0);
        for (self.delayed.items) |m| try self.appendSnapshotMsg(&buf, m, false, 0, 0);
        for (self.inflight.values()) |e| try self.appendSnapshotMsg(&buf, e.msg, true, e.lease_nonce, e.visible_at_ms);

        var crc = std.hash.crc.Crc32.init();
        crc.update(buf.items);
        try appendU32(self.gpa, &buf, crc.final());

        var file = try std.Io.Dir.cwd().createFile(self.io, self.snapshot_path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, buf.items);
        if (self.wal.fsync) try file.sync(self.io);
    }

    fn appendSnapshotMsg(self: *Store, buf: *std.ArrayList(u8), m: *message.Message, leased: bool, nonce: u64, visible_at_ms: i64) !void {
        try buf.append(self.gpa, if (leased) 1 else 0);
        try appendU64(self.gpa, buf, nonce);
        try appendI64(self.gpa, buf, visible_at_ms);
        try appendU32(self.gpa, buf, m.receive_count);
        if (m.first_received_at_ms) |fr| {
            try buf.append(self.gpa, 1);
            try appendI64(self.gpa, buf, fr);
        } else {
            try buf.append(self.gpa, 0);
        }
        var core: std.ArrayList(u8) = .empty;
        defer core.deinit(self.gpa);
        try encodeMessageCore(self.gpa, &core, m);
        try appendU32(self.gpa, buf, @intCast(core.items.len));
        try buf.appendSlice(self.gpa, core.items);
    }

    // ---- recovery ----

    const Entry = struct {
        msg: *message.Message,
        leased: bool = false,
        lease_nonce: u64 = 0,
        visible_at_ms: i64 = 0,
    };

    pub fn recover(self: *Store) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var entries: std.AutoArrayHashMapUnmanaged(u64, Entry) = .empty;
        var max_seq: u64 = 0;
        var max_nonce: u64 = 0;
        errdefer {
            for (entries.values()) |e| e.msg.destroy(self.gpa);
            entries.deinit(self.gpa);
        }

        self.loadSnapshot(&entries, &max_seq, &max_nonce) catch {};

        const buf = try wal.readAll(self.io, self.gpa, self.wal_path);
        defer self.gpa.free(buf);

        var it = wal.iter(buf);
        while (it.next() catch null) |frame| {
            try self.applyRecord(&entries, frame, &max_seq, &max_nonce);
        }

        const now = self.clock.nowMs();
        for (entries.values()) |e| {
            if (e.msg.seq > max_seq) max_seq = e.msg.seq;
            if (e.leased and e.visible_at_ms > now) {
                try self.inflight.put(self.gpa, e.msg.seq, .{
                    .msg = e.msg,
                    .visible_at_ms = e.visible_at_ms,
                    .lease_nonce = e.lease_nonce,
                });
            } else if (e.msg.delay_until_ms > now) {
                try self.delayed.push(self.gpa, e.msg);
            } else {
                try self.visible.push(self.gpa, e.msg);
            }
        }
        entries.deinit(self.gpa);

        self.next_seq = max_seq + 1;
        self.next_nonce = max_nonce + 1;
    }

    fn applyRecord(self: *Store, entries: *std.AutoArrayHashMapUnmanaged(u64, Entry), frame: wal.Frame, max_seq: *u64, max_nonce: *u64) !void {
        switch (frame.kind) {
            .send => {
                const msg = try decodeMessageCore(self.gpa, frame.payload);
                errdefer msg.destroy(self.gpa);
                if (msg.seq > max_seq.*) max_seq.* = msg.seq;
                try entries.put(self.gpa, msg.seq, .{ .msg = msg });
            },
            .lease => {
                const seq = std.mem.readInt(u64, frame.payload[0..8], .little);
                const nonce = std.mem.readInt(u64, frame.payload[8..16], .little);
                const vis = std.mem.readInt(i64, frame.payload[16..24], .little);
                if (nonce > max_nonce.*) max_nonce.* = nonce;
                if (entries.getPtr(seq)) |e| {
                    e.leased = true;
                    e.lease_nonce = nonce;
                    e.visible_at_ms = vis;
                    e.msg.receive_count += 1;
                }
            },
            .delete_lease, .drop_retention => {
                const seq = std.mem.readInt(u64, frame.payload[0..8], .little);
                if (entries.fetchSwapRemove(seq)) |kv| kv.value.msg.destroy(self.gpa);
            },
            .expire_lease => {
                const seq = std.mem.readInt(u64, frame.payload[0..8], .little);
                if (entries.getPtr(seq)) |e| e.leased = false;
            },
            .change_vis => {
                const seq = std.mem.readInt(u64, frame.payload[0..8], .little);
                const vis = std.mem.readInt(i64, frame.payload[16..24], .little);
                if (entries.getPtr(seq)) |e| e.visible_at_ms = vis;
            },
            .purge => {
                for (entries.values()) |e| e.msg.destroy(self.gpa);
                entries.clearRetainingCapacity();
            },
        }
    }

    fn loadSnapshot(self: *Store, entries: *std.AutoArrayHashMapUnmanaged(u64, Entry), max_seq: *u64, max_nonce: *u64) !void {
        const buf = std.Io.Dir.cwd().readFileAlloc(self.io, self.snapshot_path, self.gpa, std.Io.Limit.limited(1 << 30)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.gpa.free(buf);
        if (buf.len < 4) return error.Corrupt;

        var cur = Cursor{ .buf = buf };
        const m = try cur.rdU32();
        if (m != snapshot_magic) return error.Corrupt;
        // verify crc (last 4 bytes over everything before)
        if (buf.len < 4) return error.Corrupt;
        const body = buf[0 .. buf.len - 4];
        const stored_crc = std.mem.readInt(u32, buf[buf.len - 4 ..][0..4], .little);
        var c = std.hash.crc.Crc32.init();
        c.update(body);
        if (c.final() != stored_crc) return error.Corrupt;

        const ns = try cur.rdU64();
        const nn = try cur.rdU64();
        if (ns > max_seq.* + 1) max_seq.* = ns - 1;
        if (nn > max_nonce.* + 1) max_nonce.* = nn - 1;
        const count = try cur.rdU32();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const leased = (try cur.rdU8()) != 0;
            const nonce = try cur.rdU64();
            const visible_at = try cur.rdI64();
            const rc = try cur.rdU32();
            const has_fr = (try cur.rdU8()) != 0;
            const fr: ?i64 = if (has_fr) try cur.rdI64() else null;
            const core_len = try cur.rdU32();
            const core = try cur.bytes(core_len);
            const msg = try decodeMessageCore(self.gpa, core);
            errdefer msg.destroy(self.gpa);
            msg.receive_count = rc;
            msg.first_received_at_ms = fr;
            if (msg.seq > max_seq.*) max_seq.* = msg.seq;
            if (nonce > max_nonce.*) max_nonce.* = nonce;
            try entries.put(self.gpa, msg.seq, .{ .msg = msg, .leased = leased, .lease_nonce = nonce, .visible_at_ms = visible_at });
        }
    }
};

// ---- message core (de)serialization, shared by WAL send + snapshot ----

fn appendU64(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}
fn appendI64(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: i64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(i64, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}
fn appendU32(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}
fn appendU16(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}

fn appendBlobU32(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), bytes: []const u8) !void {
    try appendU32(gpa, buf, @intCast(bytes.len));
    try buf.appendSlice(gpa, bytes);
}
fn appendBlobU16(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), bytes: []const u8) !void {
    try appendU16(gpa, buf, @intCast(bytes.len));
    try buf.appendSlice(gpa, bytes);
}
fn appendOptU8Len(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), maybe: ?[]const u8) !void {
    const bytes = maybe orelse "";
    try buf.append(gpa, @intCast(bytes.len));
    try buf.appendSlice(gpa, bytes);
}
fn appendOptU16Len(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), maybe: ?[]const u8) !void {
    const bytes = maybe orelse "";
    try appendU16(gpa, buf, @intCast(bytes.len));
    try buf.appendSlice(gpa, bytes);
}

fn encodeMessageCore(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), msg: *const message.Message) !void {
    try appendU64(gpa, buf, msg.seq);
    try appendI64(gpa, buf, msg.sent_at_ms);
    try appendI64(gpa, buf, msg.delay_until_ms);
    try buf.appendSlice(gpa, &msg.id);
    try appendBlobU32(gpa, buf, msg.body);

    // attributes blob
    var attrs_blob: std.ArrayList(u8) = .empty;
    defer attrs_blob.deinit(gpa);
    try appendU32(gpa, &attrs_blob, @intCast(msg.attributes.len));
    for (msg.attributes) |a| {
        try appendBlobU16(gpa, &attrs_blob, a.name);
        try appendBlobU16(gpa, &attrs_blob, a.data_type);
        if (a.string_value) |v| {
            try attrs_blob.append(gpa, 1);
            try appendBlobU32(gpa, &attrs_blob, v);
        } else try attrs_blob.append(gpa, 0);
        if (a.binary_value) |v| {
            try attrs_blob.append(gpa, 1);
            try appendBlobU32(gpa, &attrs_blob, v);
        } else try attrs_blob.append(gpa, 0);
    }
    try appendBlobU32(gpa, buf, attrs_blob.items);

    try appendOptU8Len(gpa, buf, msg.group_id);
    try appendOptU8Len(gpa, buf, msg.dedup_id);
    try appendOptU16Len(gpa, buf, msg.trace_header);
}

const Cursor = struct {
    buf: []const u8,
    pos: usize = 0,

    fn need(self: *Cursor, n: usize) ![]const u8 {
        if (self.pos + n > self.buf.len) return error.Corrupt;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn rdU8(self: *Cursor) !u8 {
        return (try self.need(1))[0];
    }
    fn rdU16(self: *Cursor) !u16 {
        return std.mem.readInt(u16, (try self.need(2))[0..2], .little);
    }
    fn rdU32(self: *Cursor) !u32 {
        return std.mem.readInt(u32, (try self.need(4))[0..4], .little);
    }
    fn rdU64(self: *Cursor) !u64 {
        return std.mem.readInt(u64, (try self.need(8))[0..8], .little);
    }
    fn rdI64(self: *Cursor) !i64 {
        return std.mem.readInt(i64, (try self.need(8))[0..8], .little);
    }
    fn bytes(self: *Cursor, n: u32) ![]const u8 {
        return self.need(n);
    }
};

fn dupeOpt(gpa: std.mem.Allocator, bytes: []const u8) !?[]const u8 {
    if (bytes.len == 0) return null;
    return try gpa.dupe(u8, bytes);
}

fn decodeMessageCore(gpa: std.mem.Allocator, payload: []const u8) !*message.Message {
    var cur = Cursor{ .buf = payload };
    const msg = try gpa.create(message.Message);
    errdefer gpa.destroy(msg);

    msg.* = .{
        .id = undefined,
        .seq = try cur.rdU64(),
        .body = "",
        .md5_of_body = undefined,
        .md5_of_attrs = null,
        .attributes = &.{},
        .sent_at_ms = try cur.rdI64(),
        .delay_until_ms = try cur.rdI64(),
        .receive_count = 0,
        .first_received_at_ms = null,
    };
    @memcpy(&msg.id, try cur.bytes(36));

    const body_len = try cur.rdU32();
    msg.body = try gpa.dupe(u8, try cur.bytes(body_len));
    errdefer gpa.free(msg.body);
    message.computeBodyMd5(&msg.md5_of_body, msg.body);

    const attrs_blob_len = try cur.rdU32();
    const attrs_blob = try cur.bytes(attrs_blob_len);
    var ac = Cursor{ .buf = attrs_blob };
    const attr_count = try ac.rdU32();
    var attrs = try gpa.alloc(message.MessageAttribute, attr_count);
    var built: usize = 0;
    errdefer {
        for (attrs[0..built]) |a| {
            gpa.free(a.name);
            gpa.free(a.data_type);
            if (a.string_value) |v| gpa.free(v);
            if (a.binary_value) |v| gpa.free(v);
        }
        gpa.free(attrs);
    }
    var ai: u32 = 0;
    while (ai < attr_count) : (ai += 1) {
        const name = try gpa.dupe(u8, try ac.bytes(try ac.rdU16()));
        const data_type = try gpa.dupe(u8, try ac.bytes(try ac.rdU16()));
        var sv: ?[]const u8 = null;
        var bv: ?[]const u8 = null;
        if ((try ac.rdU8()) != 0) sv = try gpa.dupe(u8, try ac.bytes(try ac.rdU32()));
        if ((try ac.rdU8()) != 0) bv = try gpa.dupe(u8, try ac.bytes(try ac.rdU32()));
        attrs[ai] = .{ .name = name, .data_type = data_type, .string_value = sv, .binary_value = bv };
        built += 1;
    }
    msg.attributes = attrs;
    if (attr_count > 0) {
        var md: [32]u8 = undefined;
        try message.computeAttrsMd5(gpa, &md, attrs);
        msg.md5_of_attrs = md;
    }

    msg.group_id = try dupeOpt(gpa, try cur.bytes(try cur.rdU8()));
    msg.dedup_id = try dupeOpt(gpa, try cur.bytes(try cur.rdU8()));
    msg.trace_header = try dupeOpt(gpa, try cur.bytes(try cur.rdU16()));

    return msg;
}

// ---- vtable adapter for queue.Store ----

pub const vtable: queue.StoreVTable = .{
    .deinit = vtDeinit,
    .purge = vtPurge,
    .count_visible = vtCountVisible,
    .count_in_flight = vtCountInFlight,
    .count_delayed = vtCountDelayed,
};

fn vtDeinit(ctx: *anyopaque) void {
    cast(ctx).deinit();
}
fn vtPurge(ctx: *anyopaque) anyerror!void {
    try cast(ctx).purge();
}
fn vtCountVisible(ctx: *anyopaque) u64 {
    return cast(ctx).countVisible();
}
fn vtCountInFlight(ctx: *anyopaque) u64 {
    return cast(ctx).countInFlight();
}
fn vtCountDelayed(ctx: *anyopaque) u64 {
    return cast(ctx).countDelayed();
}
fn cast(ctx: *anyopaque) *Store {
    return @ptrCast(@alignCast(ctx));
}

// ---- tests ----

const testing = std.testing;

const TestEnv = struct {
    threaded: *std.Io.Threaded,
    io: std.Io,
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    q: *queue.Queue,
    wal_path: []const u8,
    snap_path: []const u8,

    fn init(retention_sec: i64) !TestEnv {
        const threaded = try testing.allocator.create(std.Io.Threaded);
        threaded.* = std.Io.Threaded.init(testing.allocator, .{});
        const io = threaded.io();
        const tmp = std.testing.tmpDir(.{});
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const a = arena.allocator();
        const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        try std.Io.Dir.createDirPath(.cwd(), io, dir);
        const wal_path = try std.fs.path.join(a, &.{ dir, "messages.log" });
        const snap_path = try std.fs.path.join(a, &.{ dir, "snapshot.bin" });

        const q = try a.create(queue.Queue);
        var attrs: queue.AttrMap = .empty;
        try attrs.put(a, "MessageRetentionPeriod", .{ .integer = retention_sec });
        q.* = .{
            .id = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },
            .name = "t",
            .kind = .standard,
            .attributes = attrs,
            .tags = .empty,
            .created_at = 0,
            .last_modified_at = 0,
            .arena = undefined,
        };
        return .{ .threaded = threaded, .io = io, .tmp = tmp, .arena = arena, .q = q, .wal_path = wal_path, .snap_path = snap_path };
    }

    fn deinit(self: *TestEnv) void {
        self.tmp.cleanup();
        self.arena.deinit();
        self.threaded.deinit();
        testing.allocator.destroy(self.threaded);
    }
};

fn makeMsg(gpa: std.mem.Allocator, body: []const u8, delay_until_ms: i64, sent_at_ms: i64) !*message.Message {
    const msg = try gpa.create(message.Message);
    msg.* = .{
        .id = undefined,
        .seq = 0,
        .body = try gpa.dupe(u8, body),
        .md5_of_body = undefined,
        .md5_of_attrs = null,
        .attributes = try gpa.alloc(message.MessageAttribute, 0),
        .sent_at_ms = sent_at_ms,
        .delay_until_ms = delay_until_ms,
        .receive_count = 0,
        .first_received_at_ms = null,
    };
    @memcpy(&msg.id, "00000000-0000-4000-8000-000000000000");
    message.computeBodyMd5(&msg.md5_of_body, msg.body);
    return msg;
}

test "send enqueues visible vs delayed" {
    var env = try TestEnv.init(345_600);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    try store.send(try makeMsg(testing.allocator, "now", 0, 1000));
    try store.send(try makeMsg(testing.allocator, "later", 5000, 1000));
    try testing.expectEqual(@as(u64, 1), store.countVisible());
    try testing.expectEqual(@as(u64, 1), store.countDelayed());
}

test "receive moves to inflight then delete removes" {
    var env = try TestEnv.init(345_600);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    try store.send(try makeMsg(testing.allocator, "hi", 0, 1000));
    const got = try store.receive(env.arena.allocator(), 10, 30_000, 1000);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u64, 0), store.countVisible());
    try testing.expectEqual(@as(u64, 1), store.countInFlight());
    try testing.expectEqual(@as(u32, 1), got[0].msg.receive_count);

    const h = try receipt.decode(got[0].receipt_handle);
    try store.deleteLease(h.msg_seq, h.lease_nonce);
    try testing.expectEqual(@as(u64, 0), store.countInFlight());
}

test "delete with stale nonce is no-op success" {
    var env = try TestEnv.init(345_600);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    try store.send(try makeMsg(testing.allocator, "hi", 0, 1000));
    const got = try store.receive(env.arena.allocator(), 1, 30_000, 1000);
    const h = try receipt.decode(got[0].receipt_handle);
    try store.deleteLease(h.msg_seq, h.lease_nonce + 999); // wrong nonce
    try testing.expectEqual(@as(u64, 1), store.countInFlight()); // still there
    try store.deleteLease(h.msg_seq, h.lease_nonce); // correct
    try testing.expectEqual(@as(u64, 0), store.countInFlight());
}

test "tick promotes delayed and expired inflight" {
    var env = try TestEnv.init(345_600);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    try store.send(try makeMsg(testing.allocator, "d", 2000, 1000)); // delayed until 2000
    store.tick(1500);
    try testing.expectEqual(@as(u64, 1), store.countDelayed());
    store.tick(2000);
    try testing.expectEqual(@as(u64, 1), store.countVisible());

    const got = try store.receive(env.arena.allocator(), 1, 30_000, 2000);
    _ = got;
    try testing.expectEqual(@as(u64, 1), store.countInFlight());
    store.tick(2000 + 30_000); // lease expires
    try testing.expectEqual(@as(u64, 0), store.countInFlight());
    try testing.expectEqual(@as(u64, 1), store.countVisible());
}

test "tick drops retention-expired" {
    var env = try TestEnv.init(60); // 60s retention
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    try store.send(try makeMsg(testing.allocator, "old", 0, 1000)); // sent at 1000ms
    store.tick(1000 + 61_000); // 61s later
    try testing.expectEqual(@as(u64, 0), store.countVisible());
}

test "recover rebuilds state from WAL" {
    var env = try TestEnv.init(345_600);
    defer env.deinit();
    {
        var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
        defer store.deinit();
        try store.send(try makeMsg(testing.allocator, "a", 0, 1000));
        try store.send(try makeMsg(testing.allocator, "b", 0, 1000));
        const got = try store.receive(env.arena.allocator(), 1, 30_000, 1000);
        const h = try receipt.decode(got[0].receipt_handle);
        try store.deleteLease(h.msg_seq, h.lease_nonce); // delete "a"
    }
    var store2 = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 2000), env.q, env.wal_path, env.snap_path, false);
    defer store2.deinit();
    try store2.recover();
    // "a" deleted, "b" still visible
    try testing.expectEqual(@as(u64, 1), store2.countVisible());
    try testing.expectEqual(@as(u64, 0), store2.countInFlight());
    try testing.expectEqual(@as(u64, 3), store2.next_seq);
}

test "recover restores receive_count" {
    var env = try TestEnv.init(345_600);
    defer env.deinit();
    {
        var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
        defer store.deinit();
        try store.send(try makeMsg(testing.allocator, "a", 0, 1000));
        // receive, expire, receive again -> receive_count 2
        _ = try store.receive(env.arena.allocator(), 1, 1000, 1000);
        store.tick(2001); // expire lease (visible_at=2000)
        _ = try store.receive(env.arena.allocator(), 1, 1000, 3000);
    }
    var store2 = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 10_000), env.q, env.wal_path, env.snap_path, false);
    defer store2.deinit();
    try store2.recover();
    // lease at vis 4000 already passed by now=10000 -> visible
    try testing.expectEqual(@as(u64, 1), store2.countVisible());
    const got = try store2.receive(env.arena.allocator(), 1, 1000, 10_000);
    try testing.expectEqual(@as(u32, 3), got[0].msg.receive_count);
}

test "purge clears all" {
    var env = try TestEnv.init(345_600);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();
    try store.send(try makeMsg(testing.allocator, "a", 0, 1000));
    try store.send(try makeMsg(testing.allocator, "b", 3000, 1000));
    try store.purge();
    try testing.expectEqual(@as(u64, 0), store.countVisible());
    try testing.expectEqual(@as(u64, 0), store.countDelayed());
}
