const std = @import("std");
const message = @import("../message.zig");
const Message = message.Message;

pub const dedup_window_ms: i64 = 5 * 60 * 1000;

pub const Scope = enum { queue, message_group };
pub const Throughput = enum { per_queue, per_message_group };

pub const DedupEntry = struct {
    msg_id: [36]u8,
    seq: u64,
    cached_at_ms: i64,
    md5_of_body: [32]u8,
    md5_of_attrs: ?[32]u8,
};

// One ordered queue per MessageGroupId. `pending` holds not-yet-received
// messages in send order (index 0 = head). `inflight_seq` is the seq of the
// single message from this group currently leased; while set the group is
// blocked and no further messages are delivered until that lease is resolved.
pub const GroupQueue = struct {
    pending: std.ArrayListUnmanaged(*Message) = .empty,
    inflight_seq: ?u64 = null,
};

pub const ReceivedRecord = struct {
    msg_seq: u64,
    lease_nonce: u64,
    visible_at_ms: i64,
};

pub const CachedReceive = struct {
    cached_at_ms: i64,
    records: []ReceivedRecord,
};

pub const FifoState = struct {
    gpa: std.mem.Allocator,
    groups: std.StringArrayHashMapUnmanaged(*GroupQueue) = .empty,
    dedup: std.AutoArrayHashMapUnmanaged([32]u8, DedupEntry) = .empty,
    receive_attempts: std.StringArrayHashMapUnmanaged(CachedReceive) = .empty,
    scope: Scope = .queue,
    throughput: Throughput = .per_queue,

    pub fn deinit(self: *FifoState) void {
        // Pending messages are owned by the store; the store destroys them
        // before calling deinit. Here we only free our own structures.
        for (self.groups.keys(), self.groups.values()) |k, g| {
            g.pending.deinit(self.gpa);
            self.gpa.destroy(g);
            self.gpa.free(k);
        }
        self.groups.deinit(self.gpa);
        self.dedup.deinit(self.gpa);
        for (self.receive_attempts.keys(), self.receive_attempts.values()) |k, v| {
            self.gpa.free(v.records);
            self.gpa.free(k);
        }
        self.receive_attempts.deinit(self.gpa);
    }

    // Destroys all pending messages across groups (used on store deinit/purge).
    pub fn destroyPending(self: *FifoState) void {
        for (self.groups.values()) |g| {
            for (g.pending.items) |m| m.destroy(self.gpa);
            g.pending.clearRetainingCapacity();
            g.inflight_seq = null;
        }
    }

    pub fn getOrCreateGroup(self: *FifoState, group_id: []const u8) !*GroupQueue {
        const gop = try self.groups.getOrPut(self.gpa, group_id);
        if (!gop.found_existing) {
            const g = try self.gpa.create(GroupQueue);
            g.* = .{};
            gop.key_ptr.* = try self.gpa.dupe(u8, group_id);
            gop.value_ptr.* = g;
        }
        return gop.value_ptr.*;
    }

    pub fn removeGroup(self: *FifoState, group_id: []const u8) void {
        if (self.groups.fetchSwapRemove(group_id)) |kv| {
            kv.value.pending.deinit(self.gpa);
            self.gpa.destroy(kv.value);
            self.gpa.free(kv.key);
        }
    }

    pub fn cacheReceive(self: *FifoState, attempt_id: []const u8, now_ms: i64, records: []ReceivedRecord) !void {
        const gop = try self.receive_attempts.getOrPut(self.gpa, attempt_id);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.records);
        } else {
            gop.key_ptr.* = try self.gpa.dupe(u8, attempt_id);
        }
        gop.value_ptr.* = .{ .cached_at_ms = now_ms, .records = records };
    }

    // Drops dedup and receive-attempt entries older than the 5-minute window.
    pub fn prune(self: *FifoState, now_ms: i64) void {
        var di: usize = 0;
        while (di < self.dedup.count()) {
            if (now_ms - self.dedup.values()[di].cached_at_ms > dedup_window_ms) {
                self.dedup.swapRemoveAt(di);
            } else di += 1;
        }
        var ri: usize = 0;
        while (ri < self.receive_attempts.count()) {
            if (now_ms - self.receive_attempts.values()[ri].cached_at_ms > dedup_window_ms) {
                const key = self.receive_attempts.keys()[ri];
                const records = self.receive_attempts.values()[ri].records;
                self.receive_attempts.swapRemoveAt(ri);
                self.gpa.free(records);
                self.gpa.free(key);
            } else ri += 1;
        }
    }
};

// SHA-256 over the dedup content. When scope is message_group the group id is
// mixed in so identical bodies in different groups are not treated as dupes.
pub fn dedupKey(scope: Scope, group_id: []const u8, content: []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    if (scope == .message_group) {
        h.update(group_id);
        h.update(&[_]u8{0});
    }
    h.update(content);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

const testing = std.testing;

test "dedupKey matches plain sha256 for queue scope" {
    const k = dedupKey(.queue, "ignored", "hello");
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hello", &expected, .{});
    try testing.expectEqualSlices(u8, &expected, &k);
}

test "dedupKey differs across groups when scope is message_group" {
    const a = dedupKey(.message_group, "g1", "x");
    const b = dedupKey(.message_group, "g2", "x");
    try testing.expect(!std.mem.eql(u8, &a, &b));
    // queue scope ignores group id
    const c = dedupKey(.queue, "g1", "x");
    const d = dedupKey(.queue, "g2", "x");
    try testing.expectEqualSlices(u8, &c, &d);
}
