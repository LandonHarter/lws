const std = @import("std");
const queue = @import("../queue.zig");
const message_store = @import("message_store.zig");
const time = @import("core").time;
const idmod = @import("core").id;

pub const State = enum {
    running,
    completed,
    cancelled,
    failed,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .running => "RUNNING",
            .completed => "COMPLETED",
            .cancelled => "CANCELLED",
            .failed => "FAILED",
        };
    }
};

// Retained in the list output for one hour after a task finishes.
const retention_ms: i64 = 60 * 60 * 1000;

pub const Task = struct {
    id: [36]u8,
    src: *queue.Queue,
    dst: *queue.Queue,
    rate_per_sec: u32, // 0 = unlimited
    started_at_ms: i64,
    finished_at_ms: i64 = 0,
    state: State = .running,
    moved: u64 = 0,
    failed: u64 = 0,
    thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = .init(false),
    mgr: *Manager,
};

// Snapshot of a task's observable fields, copied under the manager mutex so the
// caller can render it without racing the worker thread.
pub const TaskInfo = struct {
    id: [36]u8,
    src: *queue.Queue,
    dst: *queue.Queue,
    rate_per_sec: u32,
    started_at_ms: i64,
    state: State,
    moved: u64,
};

pub const Manager = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: time.Clock,
    rng: std.Random,
    tasks: std.AutoArrayHashMapUnmanaged([36]u8, *Task) = .empty,
    by_src: std.StringArrayHashMapUnmanaged(*Task) = .empty, // src queue name -> active task
    mutex: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, clock: time.Clock, rng: std.Random) Manager {
        return .{ .gpa = gpa, .io = io, .clock = clock, .rng = rng };
    }

    // Signals every worker to stop, joins them, then frees all task state.
    pub fn deinit(self: *Manager) void {
        for (self.tasks.values()) |t| t.cancel.store(true, .release);
        for (self.tasks.values()) |t| {
            if (t.thread) |th| th.join();
            self.gpa.destroy(t);
        }
        self.tasks.deinit(self.gpa);
        self.by_src.deinit(self.gpa);
    }

    pub const StartError = error{MoveTaskInProgress} || std.mem.Allocator.Error || std.Thread.SpawnError;

    // Begins moving messages from `src` to `dst`. Errors if a task is already
    // running for `src`. The returned pointer is owned by the manager.
    pub fn start(self: *Manager, src: *queue.Queue, dst: *queue.Queue, rate: u32) StartError!*Task {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.pruneLocked();

        if (self.by_src.get(src.name)) |existing| {
            if (existing.state == .running) return error.MoveTaskInProgress;
        }

        const t = try self.gpa.create(Task);
        errdefer self.gpa.destroy(t);
        t.* = .{
            .id = undefined,
            .src = src,
            .dst = dst,
            .rate_per_sec = rate,
            .started_at_ms = self.clock.nowMs(),
            .mgr = self,
        };
        idmod.uuidV4(self.rng, &t.id);

        try self.tasks.put(self.gpa, t.id, t);
        errdefer _ = self.tasks.swapRemove(t.id);
        try self.by_src.put(self.gpa, src.name, t);

        t.thread = try std.Thread.spawn(.{}, worker, .{t});
        return t;
    }

    // Stops a running task. Returns the approximate number of messages moved so
    // far, or null if the handle is unknown.
    pub fn cancel(self: *Manager, id: [36]u8) ?u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const t = self.tasks.get(id) orelse return null;
        t.cancel.store(true, .release);
        return t.moved;
    }

    // Copies task snapshots into `arena`, optionally filtered to a source queue.
    pub fn list(self: *Manager, arena: std.mem.Allocator, src_filter: ?*queue.Queue) ![]TaskInfo {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.pruneLocked();

        var out: std.ArrayList(TaskInfo) = .empty;
        for (self.tasks.values()) |t| {
            if (src_filter) |f| if (f != t.src) continue;
            try out.append(arena, .{
                .id = t.id,
                .src = t.src,
                .dst = t.dst,
                .rate_per_sec = t.rate_per_sec,
                .started_at_ms = t.started_at_ms,
                .state = t.state,
                .moved = t.moved,
            });
        }
        return out.toOwnedSlice(arena);
    }

    // Removes finished tasks whose retention window has elapsed. Caller holds
    // the mutex. Finished tasks' worker threads have already exited.
    fn pruneLocked(self: *Manager) void {
        const now = self.clock.nowMs();
        var i: usize = 0;
        while (i < self.tasks.count()) {
            const t = self.tasks.values()[i];
            if (t.state != .running and now - t.finished_at_ms > retention_ms) {
                if (t.thread) |th| th.join();
                if (self.by_src.get(t.src.name)) |cur| {
                    if (cur == t) _ = self.by_src.swapRemove(t.src.name);
                }
                _ = self.tasks.swapRemoveAt(i);
                self.gpa.destroy(t);
            } else i += 1;
        }
    }

    fn finish(self: *Manager, t: *Task, state: State) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        t.state = state;
        t.finished_at_ms = self.clock.nowMs();
    }

    fn recordMoved(self: *Manager, t: *Task) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        t.moved += 1;
    }

    fn recordFailed(self: *Manager, t: *Task) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        t.failed += 1;
    }
};

fn storeOf(q: *queue.Queue) ?*message_store.Store {
    const s = q.store orelse return null;
    return @ptrCast(@alignCast(s.ctx));
}

fn worker(t: *Task) void {
    const mgr = t.mgr;
    const src = storeOf(t.src) orelse return mgr.finish(t, .failed);
    const dst = storeOf(t.dst) orelse return mgr.finish(t, .failed);

    const interval_ms: i64 = if (t.rate_per_sec > 0) @divTrunc(1000, @as(i64, t.rate_per_sec)) else 0;

    while (!t.cancel.load(.acquire)) {
        if (interval_ms > 0) {
            std.Io.sleep(mgr.io, std.Io.Duration.fromMilliseconds(interval_ms), .awake) catch {};
        }
        const moved = src.moveOneTo(dst) catch {
            mgr.recordFailed(t);
            continue;
        };
        if (!moved) return mgr.finish(t, .completed);
        mgr.recordMoved(t);
    }
    mgr.finish(t, .cancelled);
}
