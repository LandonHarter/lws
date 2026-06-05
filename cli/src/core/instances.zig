const std = @import("std");
const Io = std.Io;

pub const Instance = struct {
    service: []const u8,
    name: []const u8,
    pid: std.posix.pid_t,
    port: u16,
    file: []const u8,

    pub fn deinit(self: Instance, allocator: std.mem.Allocator) void {
        allocator.free(self.service);
        allocator.free(self.name);
        allocator.free(self.file);
    }
};

fn regDir(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, ".lws", ".instances" });
}

fn regFile(allocator: std.mem.Allocator, root: []const u8, service: []const u8, name: []const u8) ![]u8 {
    const dir = try regDir(allocator, root);
    defer allocator.free(dir);
    const base = try std.fmt.allocPrint(allocator, "{s}__{s}.txt", .{ service, name });
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ dir, base });
}

pub fn write(
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    service: []const u8,
    name: []const u8,
    pid: std.posix.pid_t,
    port: u16,
) !void {
    const dir = try regDir(allocator, root);
    defer allocator.free(dir);
    try std.Io.Dir.createDirPath(.cwd(), io, dir);

    const path = try regFile(allocator, root, service, name);
    defer allocator.free(path);

    const content = try std.fmt.allocPrint(
        allocator,
        "service={s}\nname={s}\npid={d}\nport={d}\n",
        .{ service, name, pid, port },
    );
    defer allocator.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

pub fn remove(allocator: std.mem.Allocator, io: Io, root: []const u8, service: []const u8, name: []const u8) !void {
    const path = try regFile(allocator, root, service, name);
    defer allocator.free(path);
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

pub fn list(allocator: std.mem.Allocator, io: Io, root: []const u8) ![]Instance {
    const dir_path = try regDir(allocator, root);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
        return allocator.alloc(Instance, 0);
    };
    defer dir.close(io);

    var out: std.ArrayList(Instance) = .empty;
    errdefer {
        for (out.items) |inst| inst.deinit(allocator);
        out.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;

        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch {
            allocator.free(path);
            continue;
        };
        defer allocator.free(raw);

        const inst = parse(allocator, raw, path) catch {
            allocator.free(path);
            continue;
        };
        try out.append(allocator, inst);
    }

    return out.toOwnedSlice(allocator);
}

fn parse(allocator: std.mem.Allocator, raw: []const u8, file: []const u8) !Instance {
    var service: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var pid: ?std.posix.pid_t = null;
    var port: ?u16 = null;

    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const val = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "service")) {
            service = val;
        } else if (std.mem.eql(u8, key, "name")) {
            name = val;
        } else if (std.mem.eql(u8, key, "pid")) {
            pid = try std.fmt.parseInt(std.posix.pid_t, val, 10);
        } else if (std.mem.eql(u8, key, "port")) {
            port = try std.fmt.parseInt(u16, val, 10);
        }
    }

    return .{
        .service = try allocator.dupe(u8, service orelse return error.MissingField),
        .name = try allocator.dupe(u8, name orelse return error.MissingField),
        .pid = pid orelse return error.MissingField,
        .port = port orelse return error.MissingField,
        .file = file,
    };
}

pub fn freeList(allocator: std.mem.Allocator, items: []Instance) void {
    for (items) |inst| inst.deinit(allocator);
    allocator.free(items);
}

pub fn alive(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}

pub fn signal(pid: std.posix.pid_t, sig: std.posix.SIG) !void {
    try std.posix.kill(pid, sig);
}
