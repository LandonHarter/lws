const std = @import("std");
const message = @import("../message.zig");
const receipt = @import("../receipt.zig");
const queue = @import("../queue.zig");
const config = @import("config");
const time_mod = @import("core").time;
const wal = @import("wal.zig");
const fifo = @import("fifo.zig");

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

// Auto-redrive instruction threaded into the receive path. When a popped
// message's receive_count+1 would exceed `max_receive_count` it is routed to
// `dlq` instead of being delivered; a null `dlq` (policy set but DLQ missing)
// means the message is dropped.
pub const Redrive = struct {
    max_receive_count: u32,
    dlq: ?*Store,
};

// Result of a send. For FIFO queues `sequence_number` is the SequenceNumber to
// echo (the monotonic seq) and `deduplicated` marks a 5-minute dedup hit whose
// message was NOT enqueued. For standard queues `sequence_number` is null.
pub const SendOutcome = struct {
    id: [36]u8,
    sequence_number: ?u64 = null,
    md5_of_body: [32]u8,
    md5_of_attrs: ?[32]u8 = null,
    deduplicated: bool = false,
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
    fifo: ?*fifo.FifoState = null,

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

        var fstate: ?*fifo.FifoState = null;
        if (q.kind == .fifo) {
            const fs = try gpa.create(fifo.FifoState);
            fs.* = .{ .gpa = gpa };
            if (q.attributes.get("DeduplicationScope")) |v| switch (v) {
                .string => |s| if (std.mem.eql(u8, s, "messageGroup")) {
                    fs.scope = .message_group;
                },
                else => {},
            };
            if (q.attributes.get("FifoThroughputLimit")) |v| switch (v) {
                .string => |s| if (std.mem.eql(u8, s, "perMessageGroupId")) {
                    fs.throughput = .per_message_group;
                },
                else => {},
            };
            fstate = fs;
        }

        return .{
            .gpa = gpa,
            .io = io,
            .clock = clock,
            .queue = q,
            .wal_path = wal_path,
            .snapshot_path = snapshot_path,
            .wal = w,
            .fifo = fstate,
        };
    }

    pub fn deinit(self: *Store) void {
        while (self.visible.pop()) |m| m.destroy(self.gpa);
        while (self.delayed.pop()) |m| m.destroy(self.gpa);
        for (self.inflight.values()) |e| e.msg.destroy(self.gpa);
        self.visible.deinit(self.gpa);
        self.delayed.deinit(self.gpa);
        self.inflight.deinit(self.gpa);
        if (self.fifo) |fs| {
            fs.destroyPending();
            fs.deinit();
            self.gpa.destroy(fs);
        }
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
    // enqueues into visible or delayed based on delay_until_ms. On a FIFO dedup
    // hit the message is freed and the cached outcome is returned instead.
    pub fn send(self: *Store, msg: *message.Message) !SendOutcome {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.fifo) |fs| return self.sendFifo(fs, msg);

        msg.seq = self.next_seq;
        self.next_seq += 1;

        try self.appendSend(msg);
        try self.enqueue(msg);
        self.afterWrite();
        self.wait.signal(self.io);
        return .{ .id = msg.id, .md5_of_body = msg.md5_of_body, .md5_of_attrs = msg.md5_of_attrs };
    }

    // FIFO send: enforce dedup, assign seq, push to the message group's tail.
    // Caller holds the mutex. Requires msg.group_id set; if msg.dedup_id is
    // null the queue must be content-based (validated by the handler).
    fn sendFifo(self: *Store, fs: *fifo.FifoState, msg: *message.Message) !SendOutcome {
        const gid = msg.group_id orelse return error.MissingGroupId;
        const content = msg.dedup_id orelse msg.body;
        const key = fifo.dedupKey(fs.scope, gid, content);
        const now = self.clock.nowMs();

        if (fs.dedup.get(key)) |e| {
            if (now - e.cached_at_ms < fifo.dedup_window_ms) {
                const outcome: SendOutcome = .{
                    .id = e.msg_id,
                    .sequence_number = e.seq,
                    .md5_of_body = e.md5_of_body,
                    .md5_of_attrs = e.md5_of_attrs,
                    .deduplicated = true,
                };
                msg.destroy(self.gpa);
                return outcome;
            }
        }

        msg.seq = self.next_seq;
        self.next_seq += 1;

        const entry: fifo.DedupEntry = .{
            .msg_id = msg.id,
            .seq = msg.seq,
            .cached_at_ms = now,
            .md5_of_body = msg.md5_of_body,
            .md5_of_attrs = msg.md5_of_attrs,
        };
        try fs.dedup.put(self.gpa, key, entry);
        try self.appendSend(msg);
        try self.appendDedup(key, entry);

        const group = try fs.getOrCreateGroup(gid);
        try group.pending.append(self.gpa, msg);

        self.afterWrite();
        self.wait.signal(self.io);
        return .{
            .id = msg.id,
            .sequence_number = msg.seq,
            .md5_of_body = msg.md5_of_body,
            .md5_of_attrs = msg.md5_of_attrs,
        };
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

    // Long-polling receive. When `wait_seconds > 0` and nothing is immediately
    // available, blocks on `self.wait` until a Send/promotion/expiry signals new
    // work or the deadline elapses. The ticker broadcasts every tick, so an empty
    // queue still wakes the waiter to re-check its deadline.
    pub fn receive(self: *Store, arena: std.mem.Allocator, max: u32, visibility_ms: i64, wait_seconds: u32, attempt_id: ?[]const u8) ![]ReceivedMessage {
        return self.receiveRedrive(arena, max, visibility_ms, wait_seconds, attempt_id, null);
    }

    // Like `receive`, but applies auto-redrive: messages whose receive_count
    // would exceed `redrive.max_receive_count` are moved to the DLQ (or dropped
    // when the DLQ is missing) before any are returned to the caller. The DLQ
    // store pointer is resolved by the caller — the receive path never touches
    // the registry, to avoid inverting the registry/store lock order.
    pub fn receiveRedrive(self: *Store, arena: std.mem.Allocator, max: u32, visibility_ms: i64, wait_seconds: u32, attempt_id: ?[]const u8, redrive: ?Redrive) ![]ReceivedMessage {
        const deadline_ms = self.clock.nowMs() + @as(i64, wait_seconds) * 1000;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (true) {
            const got = try self.tryReceiveLocked(arena, max, visibility_ms, self.clock.nowMs(), attempt_id, redrive);
            if (got.len > 0) return got;
            if (self.clock.nowMs() >= deadline_ms) return got;
            // waitUncancelable releases the mutex while parked and re-acquires on wake.
            self.wait.waitUncancelable(self.io, &self.mutex);
        }
    }

    // Caller holds the mutex. Pulls up to `max` immediately-visible messages into
    // in-flight leases; returns an empty slice when nothing is available.
    fn tryReceiveLocked(self: *Store, arena: std.mem.Allocator, max: u32, visibility_ms: i64, now_ms: i64, attempt_id: ?[]const u8, redrive: ?Redrive) ![]ReceivedMessage {
        if (self.fifo) |fs| return self.receiveFifo(fs, arena, max, visibility_ms, now_ms, attempt_id, redrive);

        var out: std.ArrayList(ReceivedMessage) = .empty;
        while (out.items.len < max) {
            const msg = self.visible.pop() orelse break;
            if (redrive) |rd| {
                if (msg.receive_count + 1 > rd.max_receive_count) {
                    try self.redriveMessageLocked(msg, rd);
                    continue;
                }
            }
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
        if (out.items.len > 0) self.afterWrite();
        return out.toOwnedSlice(arena);
    }

    // FIFO receive: deliver the head of each non-blocked group (one message per
    // group), preserving per-group order. A delivered group becomes blocked
    // (inflight_seq set) until its lease is deleted or expires. When attempt_id
    // is set, a fresh prior batch is replayed verbatim for idempotency.
    fn receiveFifo(self: *Store, fs: *fifo.FifoState, arena: std.mem.Allocator, max: u32, visibility_ms: i64, now_ms: i64, attempt_id: ?[]const u8, redrive: ?Redrive) ![]ReceivedMessage {
        if (attempt_id) |aid| {
            if (fs.receive_attempts.get(aid)) |cached| {
                if (now_ms - cached.cached_at_ms < fifo.dedup_window_ms) {
                    return self.replayReceive(arena, cached);
                }
            }
        }

        var out: std.ArrayList(ReceivedMessage) = .empty;
        var records: std.ArrayList(fifo.ReceivedRecord) = .empty;
        defer records.deinit(self.gpa);

        for (fs.groups.values()) |g| {
            if (out.items.len >= max) break;
            if (g.inflight_seq != null) continue;
            if (g.pending.items.len == 0) continue;

            const msg = g.pending.orderedRemove(0);
            if (redrive) |rd| {
                if (msg.receive_count + 1 > rd.max_receive_count) {
                    try self.redriveMessageLocked(msg, rd);
                    continue;
                }
            }
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
            g.inflight_seq = msg.seq;
            try self.appendLease(msg.seq, nonce, visible_at);
            const handle = try receipt.encode(arena, .{
                .queue_id = self.queue.id,
                .msg_seq = msg.seq,
                .lease_nonce = nonce,
                .visible_at_ms = visible_at,
            });
            try out.append(arena, .{ .msg = msg, .receipt_handle = handle });
            try records.append(self.gpa, .{ .msg_seq = msg.seq, .lease_nonce = nonce, .visible_at_ms = visible_at });
        }

        if (out.items.len > 0) {
            self.afterWrite();
            // Only cache a non-empty batch: caching an empty result would make a
            // long-poll retry (same attempt_id) replay empty forever.
            if (attempt_id) |aid| {
                const slice = try records.toOwnedSlice(self.gpa);
                errdefer self.gpa.free(slice);
                try fs.cacheReceive(aid, now_ms, slice);
            }
        }
        return out.toOwnedSlice(arena);
    }

    // Rebuilds a prior batch from a cached ReceiveRequestAttemptId. Messages
    // already deleted are skipped; surviving leases yield byte-identical
    // receipt handles (same seq/nonce/visible_at).
    fn replayReceive(self: *Store, arena: std.mem.Allocator, cached: fifo.CachedReceive) ![]ReceivedMessage {
        var out: std.ArrayList(ReceivedMessage) = .empty;
        for (cached.records) |r| {
            const e = self.inflight.get(r.msg_seq) orelse continue;
            if (e.lease_nonce != r.lease_nonce) continue;
            const handle = try receipt.encode(arena, .{
                .queue_id = self.queue.id,
                .msg_seq = r.msg_seq,
                .lease_nonce = r.lease_nonce,
                .visible_at_ms = r.visible_at_ms,
            });
            try out.append(arena, .{ .msg = e.msg, .receipt_handle = handle });
        }
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
        if (self.fifo) |fs| {
            fifoUnblock(fs, entry.msg);
            // Deleting a FIFO head's lease unblocks its group; wake a waiter.
            self.wait.signal(self.io);
        }
        entry.msg.destroy(self.gpa);
    }

    // Clears a group's in-flight lease after its head message resolves, then
    // drops the group if it has no remaining work.
    fn fifoUnblock(fs: *fifo.FifoState, msg: *message.Message) void {
        const gid = msg.group_id orelse return;
        const g = fs.groups.get(gid) orelse return;
        if (g.inflight_seq == msg.seq) g.inflight_seq = null;
        if (g.inflight_seq == null and g.pending.items.len == 0) fs.removeGroup(gid);
    }

    // Returns an expired-lease message to the front of its group, restoring
    // strict per-group order, and unblocks the group.
    fn fifoReturn(self: *Store, fs: *fifo.FifoState, msg: *message.Message) !void {
        const gid = msg.group_id orelse return error.MissingGroupId;
        const g = try fs.getOrCreateGroup(gid);
        try g.pending.insert(self.gpa, 0, msg);
        if (g.inflight_seq == msg.seq) g.inflight_seq = null;
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

    // ---- redrive / message move ----

    // Routes an already-popped message to the DLQ (preserving id/body/attrs but
    // resetting receive_count and delay), or drops it when no DLQ is reachable.
    // Caller holds this store's mutex; `dst.send` briefly takes the DLQ's mutex
    // (source-before-destination ordering). Caller must NOT hold the registry
    // mutex. Takes ownership of `msg`.
    fn redriveMessageLocked(self: *Store, msg: *message.Message, rd: Redrive) !void {
        if (rd.dlq) |dlq| {
            const copy = dupeMessage(self.gpa, msg) catch |e| {
                self.dropMovedLocked(msg);
                return e;
            };
            copy.receive_count = 0;
            copy.first_received_at_ms = null;
            copy.delay_until_ms = 0;
            copy.seq = 0;
            _ = dlq.send(copy) catch {
                copy.destroy(self.gpa);
                // DLQ send failed (e.g. type mismatch): drop rather than loop.
                self.dropMovedLocked(msg);
                return;
            };
            // Persist source removal only after the destination has the copy, so
            // a crash in between re-delivers (at-least-once) rather than loses.
            self.appendMove(msg.seq, dlq.queue.id) catch {};
            msg.destroy(self.gpa);
        } else {
            std.debug.print("[warn] redrive: dead-letter target for queue '{s}' is unreachable; dropping message seq={d}\n", .{ self.queue.name, msg.seq });
            self.dropMovedLocked(msg);
        }
        self.afterWriteLocked();
        self.wait.broadcast(self.io);
    }

    // Persists and frees a message removed from the visible set without delivery.
    fn dropMovedLocked(self: *Store, msg: *message.Message) void {
        self.appendDropRetention(msg.seq) catch {};
        msg.destroy(self.gpa);
    }

    // Pops one immediately-deliverable message without leasing or counting it:
    // the visible head (standard) or the head of the first unblocked group
    // (FIFO). Caller holds the mutex.
    fn popOneVisibleLocked(self: *Store) ?*message.Message {
        if (self.fifo) |fs| {
            for (fs.groups.values()) |g| {
                if (g.inflight_seq != null) continue;
                if (g.pending.items.len == 0) continue;
                return g.pending.orderedRemove(0);
            }
            return null;
        }
        return self.visible.pop();
    }

    // Moves one immediately-deliverable message from this store to `dst`,
    // returning false when the source has nothing left to move. Used by manual
    // message-move tasks. Locks the source and destination separately (never
    // both at once) to keep clear of the receive-path lock ordering.
    pub fn moveOneTo(self: *Store, dst: *Store) !bool {
        self.mutex.lockUncancelable(self.io);
        const msg = self.popOneVisibleLocked() orelse {
            self.mutex.unlock(self.io);
            return false;
        };
        self.mutex.unlock(self.io);

        const copy = dupeMessage(self.gpa, msg) catch |e| {
            msg.destroy(self.gpa);
            return e;
        };
        copy.receive_count = 0;
        copy.first_received_at_ms = null;
        copy.delay_until_ms = 0;
        copy.seq = 0;
        _ = dst.send(copy) catch |e| {
            copy.destroy(self.gpa);
            msg.destroy(self.gpa);
            return e;
        };

        self.mutex.lockUncancelable(self.io);
        self.appendMove(msg.seq, dst.queue.id) catch {};
        self.afterWriteLocked();
        self.mutex.unlock(self.io);

        msg.destroy(self.gpa);
        return true;
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
                if (self.fifo) |fs| {
                    self.fifoReturn(fs, entry.msg) catch continue;
                } else {
                    self.visible.push(self.gpa, entry.msg) catch continue;
                }
                self.appendExpireLease(entry.msg.seq, entry.lease_nonce) catch {};
                promoted = true;
            } else {
                i += 1;
            }
        }

        if (self.fifo) |fs| fs.prune(now_ms);

        self.dropRetention(now_ms);

        if (promoted) self.afterWriteLocked();
        // Broadcast every tick (cheap when no waiters): wakes long-poll waiters so
        // they can consume promoted messages or notice their deadline has passed.
        self.wait.broadcast(self.io);
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
                if (self.fifo) |fs| fifoUnblock(fs, entry.msg);
                self.appendDropRetention(entry.msg.seq) catch {};
                entry.msg.destroy(self.gpa);
            } else fi += 1;
        }

        // FIFO pending lives in per-group queues, not `visible`/`delayed`.
        if (self.fifo) |fs| {
            for (fs.groups.values()) |g| {
                var gi: usize = 0;
                while (gi < g.pending.items.len) {
                    const m = g.pending.items[gi];
                    if (now_ms - m.sent_at_ms > retention) {
                        _ = g.pending.orderedRemove(gi);
                        self.appendDropRetention(m.seq) catch {};
                        m.destroy(self.gpa);
                    } else gi += 1;
                }
            }
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
        if (self.fifo) |fs| {
            fs.destroyPending();
            for (fs.groups.keys(), fs.groups.values()) |k, g| {
                g.pending.deinit(self.gpa);
                self.gpa.destroy(g);
                self.gpa.free(k);
            }
            fs.groups.clearRetainingCapacity();
        }
        try self.wal.append(.purge, &.{});
        self.afterWrite();
    }

    pub fn countVisible(self: *Store) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fifo) |fs| {
            var total: u64 = 0;
            for (fs.groups.values()) |g| total += g.pending.items.len;
            return total;
        }
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
        if (self.fifo != null) return 0;
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

    // Move record: drops `seq` from this (source) store on recovery. The
    // destination queue id is recorded for diagnostics; recovery only reads seq.
    fn appendMove(self: *Store, seq: u64, dst_queue_id: [16]u8) !void {
        var p: [24]u8 = undefined;
        std.mem.writeInt(u64, p[0..8], seq, .little);
        @memcpy(p[8..24], &dst_queue_id);
        try self.wal.append(.move, &p);
    }

    // dedup_cache payload: key[32] msg_id[36] seq:u64 cached_at:i64
    //   md5_of_body[32] has_attrs:u8 [md5_of_attrs[32]]
    fn appendDedup(self: *Store, key: [32]u8, e: fifo.DedupEntry) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        try buf.appendSlice(self.gpa, &key);
        try buf.appendSlice(self.gpa, &e.msg_id);
        try appendU64(self.gpa, &buf, e.seq);
        try appendI64(self.gpa, &buf, e.cached_at_ms);
        try buf.appendSlice(self.gpa, &e.md5_of_body);
        if (e.md5_of_attrs) |m| {
            try buf.append(self.gpa, 1);
            try buf.appendSlice(self.gpa, &m);
        } else {
            try buf.append(self.gpa, 0);
        }
        try self.wal.append(.dedup_cache, buf.items);
    }

    // ---- snapshot ----

    fn writeSnapshot(self: *Store) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);

        try appendU32(self.gpa, &buf, snapshot_magic);
        try appendU64(self.gpa, &buf, self.next_seq);
        try appendU64(self.gpa, &buf, self.next_nonce);

        var fifo_pending: usize = 0;
        if (self.fifo) |fs| {
            for (fs.groups.values()) |g| fifo_pending += g.pending.items.len;
        }

        const total: u32 = @intCast(self.visible.count() + self.delayed.count() + self.inflight.count() + fifo_pending);
        try appendU32(self.gpa, &buf, total);

        for (self.visible.items) |m| try self.appendSnapshotMsg(&buf, m, false, 0, 0);
        for (self.delayed.items) |m| try self.appendSnapshotMsg(&buf, m, false, 0, 0);
        for (self.inflight.values()) |e| try self.appendSnapshotMsg(&buf, e.msg, true, e.lease_nonce, e.visible_at_ms);
        if (self.fifo) |fs| {
            for (fs.groups.values()) |g| {
                for (g.pending.items) |m| try self.appendSnapshotMsg(&buf, m, false, 0, 0);
            }
        }

        // FIFO trailer: dedup cache. has_fifo=0 for standard queues.
        if (self.fifo) |fs| {
            try buf.append(self.gpa, 1);
            try appendU32(self.gpa, &buf, @intCast(fs.dedup.count()));
            for (fs.dedup.keys(), fs.dedup.values()) |k, e| {
                try buf.appendSlice(self.gpa, &k);
                try buf.appendSlice(self.gpa, &e.msg_id);
                try appendU64(self.gpa, &buf, e.seq);
                try appendI64(self.gpa, &buf, e.cached_at_ms);
                try buf.appendSlice(self.gpa, &e.md5_of_body);
                if (e.md5_of_attrs) |m| {
                    try buf.append(self.gpa, 1);
                    try buf.appendSlice(self.gpa, &m);
                } else {
                    try buf.append(self.gpa, 0);
                }
            }
        } else {
            try buf.append(self.gpa, 0);
        }

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
        if (self.fifo) |fs| {
            try self.distributeFifo(fs, &entries, now, &max_seq);
        } else {
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
        }
        entries.deinit(self.gpa);

        self.next_seq = max_seq + 1;
        self.next_nonce = max_nonce + 1;
    }

    fn entrySeqLess(_: void, a: Entry, b: Entry) bool {
        return a.msg.seq < b.msg.seq;
    }

    // Rebuilds per-group queues in seq order: fresh leases go in-flight (and
    // block their group); everything else becomes pending. Dedup-entry seqs are
    // folded into max_seq so the seq counter never rewinds onto a deleted id.
    fn distributeFifo(self: *Store, fs: *fifo.FifoState, entries: *std.AutoArrayHashMapUnmanaged(u64, Entry), now: i64, max_seq: *u64) !void {
        const vals = try self.gpa.dupe(Entry, entries.values());
        defer self.gpa.free(vals);
        std.mem.sort(Entry, vals, {}, entrySeqLess);

        for (vals) |e| {
            if (e.msg.seq > max_seq.*) max_seq.* = e.msg.seq;
            const gid = e.msg.group_id orelse {
                e.msg.destroy(self.gpa);
                continue;
            };
            const g = try fs.getOrCreateGroup(gid);
            if (e.leased and e.visible_at_ms > now) {
                try self.inflight.put(self.gpa, e.msg.seq, .{
                    .msg = e.msg,
                    .visible_at_ms = e.visible_at_ms,
                    .lease_nonce = e.lease_nonce,
                });
                g.inflight_seq = e.msg.seq;
            } else {
                try g.pending.append(self.gpa, e.msg);
            }
        }
        for (fs.dedup.values()) |d| {
            if (d.seq > max_seq.*) max_seq.* = d.seq;
        }
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
            .delete_lease, .drop_retention, .move => {
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
                if (self.fifo) |fs| fs.dedup.clearRetainingCapacity();
            },
            .dedup_cache => {
                if (self.fifo) |fs| {
                    var cur = Cursor{ .buf = frame.payload };
                    var key: [32]u8 = undefined;
                    @memcpy(&key, try cur.bytes(32));
                    var entry: fifo.DedupEntry = undefined;
                    @memcpy(&entry.msg_id, try cur.bytes(36));
                    entry.seq = try cur.rdU64();
                    entry.cached_at_ms = try cur.rdI64();
                    @memcpy(&entry.md5_of_body, try cur.bytes(32));
                    entry.md5_of_attrs = if ((try cur.rdU8()) != 0) blk: {
                        var m: [32]u8 = undefined;
                        @memcpy(&m, try cur.bytes(32));
                        break :blk m;
                    } else null;
                    try fs.dedup.put(self.gpa, key, entry);
                }
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

        const has_fifo = (try cur.rdU8()) != 0;
        if (has_fifo) {
            if (self.fifo) |fs| {
                const dcount = try cur.rdU32();
                var di: u32 = 0;
                while (di < dcount) : (di += 1) {
                    var key: [32]u8 = undefined;
                    @memcpy(&key, try cur.bytes(32));
                    var entry: fifo.DedupEntry = undefined;
                    @memcpy(&entry.msg_id, try cur.bytes(36));
                    entry.seq = try cur.rdU64();
                    entry.cached_at_ms = try cur.rdI64();
                    @memcpy(&entry.md5_of_body, try cur.bytes(32));
                    entry.md5_of_attrs = if ((try cur.rdU8()) != 0) blk: {
                        var ma: [32]u8 = undefined;
                        @memcpy(&ma, try cur.bytes(32));
                        break :blk ma;
                    } else null;
                    try fs.dedup.put(self.gpa, key, entry);
                }
            } else return error.Corrupt;
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

// Deep-copies a message into a freshly allocated struct owned by `gpa`. Used to
// hand an independent copy to a destination store during a move/redrive while
// the original stays owned by the source until it is dropped.
fn dupeMessage(gpa: std.mem.Allocator, src: *const message.Message) !*message.Message {
    const m = try gpa.create(message.Message);
    errdefer gpa.destroy(m);

    const attrs = try gpa.alloc(message.MessageAttribute, src.attributes.len);
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
    for (src.attributes, 0..) |a, i| {
        attrs[i] = .{
            .name = try gpa.dupe(u8, a.name),
            .data_type = try gpa.dupe(u8, a.data_type),
            .string_value = if (a.string_value) |v| try gpa.dupe(u8, v) else null,
            .binary_value = if (a.binary_value) |v| try gpa.dupe(u8, v) else null,
        };
        built += 1;
    }

    m.* = .{
        .id = src.id,
        .seq = src.seq,
        .body = try gpa.dupe(u8, src.body),
        .md5_of_body = src.md5_of_body,
        .md5_of_attrs = src.md5_of_attrs,
        .attributes = attrs,
        .sent_at_ms = src.sent_at_ms,
        .delay_until_ms = src.delay_until_ms,
        .receive_count = src.receive_count,
        .first_received_at_ms = src.first_received_at_ms,
        .group_id = if (src.group_id) |g| try gpa.dupe(u8, g) else null,
        .dedup_id = if (src.dedup_id) |d| try gpa.dupe(u8, d) else null,
        .trace_header = if (src.trace_header) |t| try gpa.dupe(u8, t) else null,
    };
    return m;
}

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

    _ = try store.send(try makeMsg(testing.allocator, "now", 0, 1000));
    _ = try store.send(try makeMsg(testing.allocator, "later", 5000, 1000));
    try testing.expectEqual(@as(u64, 1), store.countVisible());
    try testing.expectEqual(@as(u64, 1), store.countDelayed());
}

test "receive moves to inflight then delete removes" {
    var env = try TestEnv.init(345_600);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    _ = try store.send(try makeMsg(testing.allocator, "hi", 0, 1000));
    const got = try store.receive(env.arena.allocator(), 10, 30_000, 0, null);
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

    _ = try store.send(try makeMsg(testing.allocator, "hi", 0, 1000));
    const got = try store.receive(env.arena.allocator(), 1, 30_000, 0, null);
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

    _ = try store.send(try makeMsg(testing.allocator, "d", 2000, 1000)); // delayed until 2000
    store.tick(1500);
    try testing.expectEqual(@as(u64, 1), store.countDelayed());
    store.tick(2000);
    try testing.expectEqual(@as(u64, 1), store.countVisible());

    const got = try store.receive(env.arena.allocator(), 1, 30_000, 0, null);
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

    _ = try store.send(try makeMsg(testing.allocator, "old", 0, 1000)); // sent at 1000ms
    store.tick(1000 + 61_000); // 61s later
    try testing.expectEqual(@as(u64, 0), store.countVisible());
}

test "recover rebuilds state from WAL" {
    var env = try TestEnv.init(345_600);
    defer env.deinit();
    {
        var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
        defer store.deinit();
        _ = try store.send(try makeMsg(testing.allocator, "a", 0, 1000));
        _ = try store.send(try makeMsg(testing.allocator, "b", 0, 1000));
        const got = try store.receive(env.arena.allocator(), 1, 30_000, 0, null);
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
        _ = try store.send(try makeMsg(testing.allocator, "a", 0, 1000));
        // receive, expire, receive again -> receive_count 2
        _ = try store.receive(env.arena.allocator(), 1, 1000, 0, null);
        store.tick(2001); // expire lease (visible_at=2000)
        _ = try store.receive(env.arena.allocator(), 1, 1000, 0, null);
    }
    var store2 = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 10_000), env.q, env.wal_path, env.snap_path, false);
    defer store2.deinit();
    try store2.recover();
    // lease at vis 4000 already passed by now=10000 -> visible
    try testing.expectEqual(@as(u64, 1), store2.countVisible());
    const got = try store2.receive(env.arena.allocator(), 1, 1000, 0, null);
    try testing.expectEqual(@as(u32, 3), got[0].msg.receive_count);
}

test "purge clears all" {
    var env = try TestEnv.init(345_600);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();
    _ = try store.send(try makeMsg(testing.allocator, "a", 0, 1000));
    _ = try store.send(try makeMsg(testing.allocator, "b", 3000, 1000));
    try store.purge();
    try testing.expectEqual(@as(u64, 0), store.countVisible());
    try testing.expectEqual(@as(u64, 0), store.countDelayed());
}

// ---- long-poll tests ----

// Drives Store.tick on its own OS thread (mirrors the production ticker) so that
// blocked long-poll receivers get woken to re-check their deadline.
const TickHelper = struct {
    store: *Store,
    io: std.Io,
    clock: time_mod.Clock,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn run(self: *TickHelper) void {
        while (!self.stop.load(.acquire)) {
            self.store.tick(self.clock.nowMs());
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
        }
    }
    fn start(self: *TickHelper) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    fn stopJoin(self: *TickHelper) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
    }
};

test "receive long-poll times out on empty queue" {
    var env = try TestEnv.init(345_600);
    defer env.deinit();
    const clock = time_mod.Clock.real(env.io);
    var store = try Store.init(testing.allocator, env.io, clock, env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    var helper = TickHelper{ .store = &store, .io = env.io, .clock = clock };
    try helper.start();
    defer helper.stopJoin();

    const t0 = clock.nowMs();
    const got = try store.receive(env.arena.allocator(), 1, 30_000, 1, null);
    const elapsed = clock.nowMs() - t0;
    try testing.expectEqual(@as(usize, 0), got.len);
    try testing.expect(elapsed >= 950 and elapsed <= 2000);
}

test "receive long-poll wakes on concurrent send" {
    var env = try TestEnv.init(345_600);
    defer env.deinit();
    const clock = time_mod.Clock.real(env.io);
    var store = try Store.init(testing.allocator, env.io, clock, env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    var helper = TickHelper{ .store = &store, .io = env.io, .clock = clock };
    try helper.start();
    defer helper.stopJoin();

    const Sender = struct {
        fn run(s: *Store, io: std.Io) void {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake) catch {};
            const m = makeMsg(testing.allocator, "x", 0, s.clock.nowMs()) catch return;
            _ = s.send(m) catch m.destroy(testing.allocator);
        }
    };
    var sender = try std.Thread.spawn(.{}, Sender.run, .{ &store, env.io });

    const t0 = clock.nowMs();
    const got = try store.receive(env.arena.allocator(), 1, 30_000, 20, null);
    const elapsed = clock.nowMs() - t0;
    sender.join();

    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expect(elapsed < 5000); // woke well before the 20s deadline
}

// ---- FIFO tests ----

fn initFifoEnv(retention_sec: i64, cbd: bool) !TestEnv {
    var env = try TestEnv.init(retention_sec);
    const a = env.arena.allocator();
    env.q.kind = .fifo;
    try env.q.attributes.put(a, "ContentBasedDeduplication", .{ .boolean = cbd });
    return env;
}

fn makeFifoMsg(gpa: std.mem.Allocator, id_byte: u8, body: []const u8, group_id: []const u8, dedup_id: ?[]const u8, sent_at_ms: i64) !*message.Message {
    const msg = try gpa.create(message.Message);
    msg.* = .{
        .id = undefined,
        .seq = 0,
        .body = try gpa.dupe(u8, body),
        .md5_of_body = undefined,
        .md5_of_attrs = null,
        .attributes = try gpa.alloc(message.MessageAttribute, 0),
        .sent_at_ms = sent_at_ms,
        .delay_until_ms = 0,
        .receive_count = 0,
        .first_received_at_ms = null,
        .group_id = try gpa.dupe(u8, group_id),
        .dedup_id = if (dedup_id) |d| try gpa.dupe(u8, d) else null,
    };
    @memcpy(&msg.id, "00000000-0000-4000-8000-0000000000xx");
    msg.id[34] = '0' + (id_byte / 10);
    msg.id[35] = '0' + (id_byte % 10);
    message.computeBodyMd5(&msg.md5_of_body, msg.body);
    return msg;
}

test "fifo send requires group id" {
    var env = try initFifoEnv(345_600, true);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    const msg = try makeMsg(testing.allocator, "x", 0, 1000); // no group_id
    try testing.expectError(error.MissingGroupId, store.send(msg));
    msg.destroy(testing.allocator);
}

test "fifo explicit dedup id suppresses duplicate" {
    var env = try initFifoEnv(345_600, false);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    const r1 = try store.send(try makeFifoMsg(testing.allocator, 1, "alpha", "g1", "d1", 1000));
    const r2 = try store.send(try makeFifoMsg(testing.allocator, 2, "beta", "g1", "d1", 1000));
    try testing.expect(!r1.deduplicated);
    try testing.expect(r2.deduplicated);
    try testing.expectEqualSlices(u8, &r1.id, &r2.id);
    try testing.expectEqual(r1.sequence_number.?, r2.sequence_number.?);
    try testing.expectEqual(@as(u64, 1), store.countVisible()); // only one enqueued
}

test "fifo content based dedup suppresses duplicate body" {
    var env = try initFifoEnv(345_600, true);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    const r1 = try store.send(try makeFifoMsg(testing.allocator, 1, "same", "g1", null, 1000));
    const r2 = try store.send(try makeFifoMsg(testing.allocator, 2, "same", "g1", null, 1000));
    try testing.expect(r2.deduplicated);
    try testing.expectEqualSlices(u8, &r1.id, &r2.id);
    try testing.expectEqual(@as(u64, 1), store.countVisible());
}

test "fifo dedup expires after window" {
    var env = try initFifoEnv(345_600, true);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    _ = try store.send(try makeFifoMsg(testing.allocator, 1, "same", "g1", null, 1000));
    // advance clock past 5min window
    store.clock = time_mod.Clock.fixed(0, 1000 + fifo.dedup_window_ms + 1);
    const r2 = try store.send(try makeFifoMsg(testing.allocator, 2, "same", "g1", null, 1000 + fifo.dedup_window_ms + 1));
    try testing.expect(!r2.deduplicated);
    try testing.expectEqual(@as(u64, 2), store.countVisible());
}

test "fifo sequence numbers are monotonic" {
    var env = try initFifoEnv(345_600, true);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    const r1 = try store.send(try makeFifoMsg(testing.allocator, 1, "a", "g1", null, 1000));
    const r2 = try store.send(try makeFifoMsg(testing.allocator, 2, "b", "g1", null, 1000));
    try testing.expect(r2.sequence_number.? > r1.sequence_number.?);
}

test "fifo per-group blocking across groups" {
    var env = try initFifoEnv(345_600, true);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    _ = try store.send(try makeFifoMsg(testing.allocator, 1, "a", "g1", null, 1000));
    _ = try store.send(try makeFifoMsg(testing.allocator, 2, "b", "g1", null, 1000));
    _ = try store.send(try makeFifoMsg(testing.allocator, 3, "c", "g2", null, 1000));

    // max=10 but only g1 head + g2 head delivered (b stays back behind a)
    const got = try store.receive(env.arena.allocator(), 10, 30_000, 0, null);
    try testing.expectEqual(@as(usize, 2), got.len);
    var bodies: [2][]const u8 = .{ got[0].msg.body, got[1].msg.body };
    std.mem.sort([]const u8, &bodies, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    try testing.expectEqualStrings("a", bodies[0]);
    try testing.expectEqualStrings("c", bodies[1]);

    // delete a (the g1 head); next receive yields b
    for (got) |rm| {
        if (std.mem.eql(u8, rm.msg.body, "a")) {
            const h = try receipt.decode(rm.receipt_handle);
            try store.deleteLease(h.msg_seq, h.lease_nonce);
        }
    }
    const got2 = try store.receive(env.arena.allocator(), 10, 30_000, 0, null);
    try testing.expectEqual(@as(usize, 1), got2.len);
    try testing.expectEqualStrings("b", got2[0].msg.body);
}

test "fifo strict order within group" {
    var env = try initFifoEnv(345_600, true);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    const bodies = [_][]const u8{ "m0", "m1", "m2", "m3", "m4" };
    for (bodies, 0..) |b, i| {
        _ = try store.send(try makeFifoMsg(testing.allocator, @intCast(i), b, "g1", null, 1000));
    }
    for (bodies) |expected| {
        const got = try store.receive(env.arena.allocator(), 1, 30_000, 0, null);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqualStrings(expected, got[0].msg.body);
        const h = try receipt.decode(got[0].receipt_handle);
        try store.deleteLease(h.msg_seq, h.lease_nonce);
    }
}

test "fifo expired lease returns to group front in order" {
    var env = try initFifoEnv(345_600, true);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    _ = try store.send(try makeFifoMsg(testing.allocator, 1, "a", "g1", null, 1000));
    _ = try store.send(try makeFifoMsg(testing.allocator, 2, "b", "g1", null, 1000));

    const got = try store.receive(env.arena.allocator(), 1, 1000, 0, null); // lease "a" vis 2000
    try testing.expectEqualStrings("a", got[0].msg.body);
    store.tick(2001); // expire -> "a" back at front
    const got2 = try store.receive(env.arena.allocator(), 1, 30_000, 0, null);
    try testing.expectEqualStrings("a", got2[0].msg.body); // still head, order preserved
}

test "fifo receive request attempt id replays batch" {
    var env = try initFifoEnv(345_600, true);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    _ = try store.send(try makeFifoMsg(testing.allocator, 1, "a", "g1", null, 1000));
    _ = try store.send(try makeFifoMsg(testing.allocator, 2, "c", "g2", null, 1000));

    const first = try store.receive(env.arena.allocator(), 10, 30_000, 0, "attempt-1");
    const replay = try store.receive(env.arena.allocator(), 10, 30_000, 0, "attempt-1");
    try testing.expectEqual(first.len, replay.len);
    for (first, replay) |f, r| {
        try testing.expectEqualSlices(u8, &f.msg.id, &r.msg.id);
        try testing.expectEqualStrings(f.receipt_handle, r.receipt_handle);
    }

    // different attempt id, but groups are blocked -> empty batch
    const other = try store.receive(env.arena.allocator(), 10, 30_000, 0, "attempt-2");
    try testing.expectEqual(@as(usize, 0), other.len);
}

test "fifo per message group throughput allows parallel groups" {
    var env = try initFifoEnv(345_600, true);
    const a = env.arena.allocator();
    try env.q.attributes.put(a, "FifoThroughputLimit", .{ .string = "perMessageGroupId" });
    try env.q.attributes.put(a, "DeduplicationScope", .{ .string = "messageGroup" });
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();
    try testing.expectEqual(fifo.Throughput.per_message_group, store.fifo.?.throughput);
    try testing.expectEqual(fifo.Scope.message_group, store.fifo.?.scope);

    _ = try store.send(try makeFifoMsg(testing.allocator, 1, "a", "g1", null, 1000));
    _ = try store.send(try makeFifoMsg(testing.allocator, 2, "b", "g2", null, 1000));
    const got = try store.receive(env.arena.allocator(), 10, 30_000, 0, null);
    try testing.expectEqual(@as(usize, 2), got.len); // both groups in flight
}

test "fifo recover rebuilds groups dedup and inflight" {
    var env = try initFifoEnv(345_600, true);
    defer env.deinit();
    {
        var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
        defer store.deinit();
        _ = try store.send(try makeFifoMsg(testing.allocator, 1, "a", "g1", null, 1000));
        _ = try store.send(try makeFifoMsg(testing.allocator, 2, "b", "g1", null, 1000));
        _ = try store.send(try makeFifoMsg(testing.allocator, 3, "c", "g2", null, 1000));
        // lease g1 head so it's in flight at restart
        _ = try store.receive(env.arena.allocator(), 1, 60_000, 0, null);
    }
    var store2 = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 2000), env.q, env.wal_path, env.snap_path, false);
    defer store2.deinit();
    try store2.recover();
    try testing.expectEqual(@as(u64, 1), store2.countInFlight()); // "a" still leased (vis 61000)
    try testing.expectEqual(@as(u64, 2), store2.countVisible()); // "b" pending + "c" pending
    try testing.expectEqual(@as(u64, 4), store2.next_seq);

    // dedup persists: re-send "a" body in g1 is suppressed
    const r = try store2.send(try makeFifoMsg(testing.allocator, 9, "a", "g1", null, 2000));
    try testing.expect(r.deduplicated);

    // g1 is blocked (head "a" in flight); only g2 head "c" deliverable
    const got = try store2.receive(env.arena.allocator(), 10, 30_000, 0, null);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("c", got[0].msg.body);
}

test "auto-redrive moves message to dlq after maxReceiveCount" {
    var src_env = try TestEnv.init(345_600);
    defer src_env.deinit();
    var dlq_env = try TestEnv.init(345_600);
    defer dlq_env.deinit();

    var src = try Store.init(testing.allocator, src_env.io, time_mod.Clock.fixed(0, 1000), src_env.q, src_env.wal_path, src_env.snap_path, false);
    defer src.deinit();
    var dlq = try Store.init(testing.allocator, dlq_env.io, time_mod.Clock.fixed(0, 1000), dlq_env.q, dlq_env.wal_path, dlq_env.snap_path, false);
    defer dlq.deinit();

    const rd: Redrive = .{ .max_receive_count = 2, .dlq = &dlq };

    _ = try src.send(try makeMsg(testing.allocator, "x", 0, 1000));

    // receive 1: count -> 1, delivered
    var got = try src.receiveRedrive(src_env.arena.allocator(), 1, 1000, 0, null, rd);
    try testing.expectEqual(@as(usize, 1), got.len);
    src.tick(2001); // expire lease

    // receive 2: count -> 2, delivered
    got = try src.receiveRedrive(src_env.arena.allocator(), 1, 1000, 0, null, rd);
    try testing.expectEqual(@as(usize, 1), got.len);
    src.tick(4001); // expire lease

    // receive 3: 2+1 > 2 -> moved to DLQ, empty result
    got = try src.receiveRedrive(src_env.arena.allocator(), 1, 1000, 0, null, rd);
    try testing.expectEqual(@as(usize, 0), got.len);
    try testing.expectEqual(@as(u64, 0), src.countVisible());
    try testing.expectEqual(@as(u64, 0), src.countInFlight());

    // DLQ now has the message; receive_count restarts at 1.
    try testing.expectEqual(@as(u64, 1), dlq.countVisible());
    const dgot = try dlq.receive(dlq_env.arena.allocator(), 1, 1000, 0, null);
    try testing.expectEqual(@as(usize, 1), dgot.len);
    try testing.expectEqualStrings("x", dgot[0].msg.body);
    try testing.expectEqual(@as(u32, 1), dgot[0].msg.receive_count);
}

test "auto-redrive drops message when dlq missing" {
    var env = try TestEnv.init(345_600);
    defer env.deinit();
    var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
    defer store.deinit();

    const rd: Redrive = .{ .max_receive_count = 1, .dlq = null };
    _ = try store.send(try makeMsg(testing.allocator, "x", 0, 1000));

    var got = try store.receiveRedrive(env.arena.allocator(), 1, 1000, 0, null, rd);
    try testing.expectEqual(@as(usize, 1), got.len); // count 1, not > 1
    store.tick(2001);

    got = try store.receiveRedrive(env.arena.allocator(), 1, 1000, 0, null, rd);
    try testing.expectEqual(@as(usize, 0), got.len); // 1+1 > 1 -> dropped
    try testing.expectEqual(@as(u64, 0), store.countVisible());
    try testing.expectEqual(@as(u64, 0), store.countInFlight());
}

test "moveOneTo transfers a visible message" {
    var src_env = try TestEnv.init(345_600);
    defer src_env.deinit();
    var dst_env = try TestEnv.init(345_600);
    defer dst_env.deinit();

    var src = try Store.init(testing.allocator, src_env.io, time_mod.Clock.fixed(0, 1000), src_env.q, src_env.wal_path, src_env.snap_path, false);
    defer src.deinit();
    var dst = try Store.init(testing.allocator, dst_env.io, time_mod.Clock.fixed(0, 1000), dst_env.q, dst_env.wal_path, dst_env.snap_path, false);
    defer dst.deinit();

    _ = try src.send(try makeMsg(testing.allocator, "m", 0, 1000));
    try testing.expect(try src.moveOneTo(&dst));
    try testing.expectEqual(@as(u64, 0), src.countVisible());
    try testing.expectEqual(@as(u64, 1), dst.countVisible());
    // nothing left to move
    try testing.expect(!try src.moveOneTo(&dst));
}

test "fifo snapshot round trip" {
    var env = try initFifoEnv(345_600, true);
    defer env.deinit();
    {
        var store = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 1000), env.q, env.wal_path, env.snap_path, false);
        defer store.deinit();
        _ = try store.send(try makeFifoMsg(testing.allocator, 1, "a", "g1", null, 1000));
        _ = try store.send(try makeFifoMsg(testing.allocator, 2, "b", "g2", null, 1000));
        try store.writeSnapshot();
        try store.wal.truncate(); // force recovery to rely on the snapshot
    }
    var store2 = try Store.init(testing.allocator, env.io, time_mod.Clock.fixed(0, 2000), env.q, env.wal_path, env.snap_path, false);
    defer store2.deinit();
    try store2.recover();
    try testing.expectEqual(@as(u64, 2), store2.countVisible());
    // dedup survived the snapshot
    const r = try store2.send(try makeFifoMsg(testing.allocator, 9, "a", "g1", null, 2000));
    try testing.expect(r.deduplicated);
}
