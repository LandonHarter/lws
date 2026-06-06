const std = @import("std");

pub const magic: u32 = 0x53515731; // 'SQW1'

pub const Kind = enum(u8) {
    send = 1,
    lease = 2,
    delete_lease = 3,
    expire_lease = 4,
    change_vis = 5,
    purge = 6,
    drop_retention = 7,
    dedup_cache = 8,
    move = 9,
};

pub const ParseError = error{ BadMagic, BadCrc, BadKind };

// Frame on disk: magic:u32 LE, length:u32 LE, kind:u8, payload:[length], crc32:u32 LE.
// crc covers (kind ++ payload).
const header_len = 4 + 4 + 1; // magic + length + kind
const trailer_len = 4; // crc

fn crcOf(kind: u8, payload: []const u8) u32 {
    var c = std.hash.crc.Crc32.init();
    c.update(&.{kind});
    c.update(payload);
    return c.final();
}

pub const WalWriter = struct {
    io: std.Io,
    file: std.Io.File,
    fsync: bool,
    offset: u64,
    path: []const u8, // borrowed; must outlive the writer

    pub fn open(io: std.Io, path: []const u8, fsync: bool) !WalWriter {
        // Open existing for read_write (preserving prior records), else create.
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.cwd().createFile(io, path, .{ .read = true }),
            else => return err,
        };
        const st = try file.stat(io);
        return .{ .io = io, .file = file, .fsync = fsync, .offset = st.size, .path = path };
    }

    pub fn close(self: *WalWriter) void {
        self.file.close(self.io);
    }

    pub fn append(self: *WalWriter, kind: Kind, payload: []const u8) !void {
        var hdr: [header_len]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], magic, .little);
        std.mem.writeInt(u32, hdr[4..8], @intCast(payload.len), .little);
        hdr[8] = @intFromEnum(kind);

        var trailer: [trailer_len]u8 = undefined;
        std.mem.writeInt(u32, &trailer, crcOf(hdr[8], payload), .little);

        try self.file.writePositionalAll(self.io, &hdr, self.offset);
        self.offset += header_len;
        try self.file.writePositionalAll(self.io, payload, self.offset);
        self.offset += payload.len;
        try self.file.writePositionalAll(self.io, &trailer, self.offset);
        self.offset += trailer_len;

        if (self.fsync) try self.file.sync(self.io);
    }

    // Reset to empty (used after a snapshot rewrites full state).
    pub fn truncate(self: *WalWriter) !void {
        self.file.close(self.io);
        self.file = try std.Io.Dir.cwd().createFile(self.io, self.path, .{ .read = true });
        self.offset = 0;
    }
};

pub const Frame = struct {
    kind: Kind,
    payload: []const u8, // slice into the source buffer
};

pub const Iterator = struct {
    buf: []const u8,
    pos: usize = 0,

    // Returns next frame, or null at clean EOF. A complete-but-corrupt frame
    // (bad magic/crc) errors; a torn trailing frame (short read) is treated as
    // EOF so a crash mid-append doesn't poison recovery.
    pub fn next(self: *Iterator) ParseError!?Frame {
        if (self.pos >= self.buf.len) return null;
        if (self.pos + header_len > self.buf.len) return null; // torn header
        const rec_magic = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
        if (rec_magic != magic) return ParseError.BadMagic;
        const length = std.mem.readInt(u32, self.buf[self.pos + 4 ..][0..4], .little);
        const kind_byte = self.buf[self.pos + 8];
        const payload_start = self.pos + header_len;
        const payload_end = payload_start + length;
        if (payload_end + trailer_len > self.buf.len) return null; // torn payload/trailer
        const payload = self.buf[payload_start..payload_end];
        const stored_crc = std.mem.readInt(u32, self.buf[payload_end..][0..4], .little);
        if (stored_crc != crcOf(kind_byte, payload)) return ParseError.BadCrc;
        if (kind_byte < 1 or kind_byte > 9) return ParseError.BadKind;
        const kind: Kind = @enumFromInt(kind_byte);
        self.pos = payload_end + trailer_len;
        return .{ .kind = kind, .payload = payload };
    }
};

pub fn iter(buf: []const u8) Iterator {
    return .{ .buf = buf };
}

// Reads the whole WAL into `gpa`. Returns empty slice if the file is absent.
pub fn readAll(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.limited(1 << 30)) catch |err| switch (err) {
        error.FileNotFound => try gpa.alloc(u8, 0),
        else => err,
    };
}

const testing = std.testing;

fn tmpPath(buf: []u8, tmp: *const std.testing.TmpDir, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name }) catch unreachable;
}

test "round-trip mixed records" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const path = tmpPath(&pbuf, &tmp, "wal.log");

    {
        var w = try WalWriter.open(io, path, false);
        defer w.close();
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            var payload: [8]u8 = undefined;
            std.mem.writeInt(u64, &payload, @intCast(i), .little);
            const kind: Kind = if (i % 2 == 0) .send else .delete_lease;
            try w.append(kind, &payload);
        }
    }

    const buf = try readAll(io, testing.allocator, path);
    defer testing.allocator.free(buf);
    var it = iter(buf);
    var count: usize = 0;
    while (try it.next()) |frame| {
        const v = std.mem.readInt(u64, frame.payload[0..8], .little);
        try testing.expectEqual(@as(u64, @intCast(count)), v);
        const want: Kind = if (count % 2 == 0) .send else .delete_lease;
        try testing.expectEqual(want, frame.kind);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 100), count);
}

test "crc corruption detected" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const path = tmpPath(&pbuf, &tmp, "wal.log");

    {
        var w = try WalWriter.open(io, path, false);
        defer w.close();
        try w.append(.send, "hello");
    }

    const buf = try readAll(io, testing.allocator, path);
    defer testing.allocator.free(buf);
    // flip a byte inside the payload
    buf[header_len] ^= 0xff;
    var it = iter(buf);
    try testing.expectError(ParseError.BadCrc, it.next());
}

test "torn trailing frame tolerated" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const path = tmpPath(&pbuf, &tmp, "wal.log");

    {
        var w = try WalWriter.open(io, path, false);
        defer w.close();
        try w.append(.send, "aaaa");
        try w.append(.send, "bbbb");
    }

    const full = try readAll(io, testing.allocator, path);
    defer testing.allocator.free(full);
    // chop the last frame's tail
    const partial = full[0 .. full.len - 3];
    var it = iter(partial);
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

test "reopen preserves prior records and appends" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const path = tmpPath(&pbuf, &tmp, "wal.log");

    {
        var w = try WalWriter.open(io, path, false);
        defer w.close();
        try w.append(.send, "one");
    }
    {
        var w = try WalWriter.open(io, path, false);
        defer w.close();
        try w.append(.send, "two");
    }

    const buf = try readAll(io, testing.allocator, path);
    defer testing.allocator.free(buf);
    var it = iter(buf);
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count);
}
