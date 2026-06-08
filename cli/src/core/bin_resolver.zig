const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const root_dir = @import("root_dir.zig");

const EnvMap = std.process.Environ.Map;

pub const Error = error{ServiceBinaryNotFound} || std.mem.Allocator.Error;

pub const Source = enum { env, install, dev };

pub const ResolveResult = struct {
    path: []u8,
    source: Source,
};

const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

pub fn resolve(
    allocator: std.mem.Allocator,
    io: Io,
    env_map: ?*const EnvMap,
    service_dir_name: []const u8,
    bin_name: []const u8,
) Error!ResolveResult {
    const file_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ bin_name, exe_suffix });
    defer allocator.free(file_name);

    if (env_map) |m| {
        if (m.get("LWS_BIN_DIR")) |env_dir| {
            if (env_dir.len > 0) {
                if (try findInDir(allocator, io, env_dir, file_name)) |path| {
                    return .{ .path = path, .source = .env };
                }
            }
        }
    }

    if (std.process.executableDirPathAlloc(io, allocator)) |self_dir| {
        defer allocator.free(self_dir);
        if (try findInDir(allocator, io, self_dir, file_name)) |path| {
            return .{ .path = path, .source = .install };
        }
    } else |_| {}

    if (root_dir.find(allocator, io)) |root| {
        defer allocator.free(root);
        const dev_dir = try std.fs.path.join(allocator, &.{ root, "services", service_dir_name, "zig-out", "bin" });
        defer allocator.free(dev_dir);
        if (try findInDir(allocator, io, dev_dir, file_name)) |path| {
            return .{ .path = path, .source = .dev };
        }
    } else |_| {}

    return error.ServiceBinaryNotFound;
}

fn findInDir(allocator: std.mem.Allocator, io: Io, dir: []const u8, file_name: []const u8) std.mem.Allocator.Error!?[]u8 {
    const candidate = try std.fs.path.join(allocator, &.{ dir, file_name });
    std.Io.Dir.accessAbsolute(io, candidate, .{}) catch {
        allocator.free(candidate);
        return null;
    };
    return candidate;
}

fn tmpAbsPath(allocator: std.mem.Allocator, io: Io, sub_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", sub_path });
}

test "findInDir returns path when file present" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "lws-sqs", .data = "" });

    const dir_path = try tmpAbsPath(allocator, io, &tmp.sub_path);
    defer allocator.free(dir_path);

    const found = try findInDir(allocator, io, dir_path, "lws-sqs");
    try std.testing.expect(found != null);
    defer if (found) |f| allocator.free(f);
    try std.testing.expect(std.mem.endsWith(u8, found.?, "lws-sqs"));
}

test "findInDir returns null when file absent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmpAbsPath(allocator, io, &tmp.sub_path);
    defer allocator.free(dir_path);

    const found = try findInDir(allocator, io, dir_path, "lws-sqs");
    try std.testing.expect(found == null);
}

test "resolve picks LWS_BIN_DIR override" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "lws-sqs", .data = "" });
    const dir_path = try tmpAbsPath(allocator, io, &tmp.sub_path);
    defer allocator.free(dir_path);

    var env = EnvMap.init(allocator);
    defer env.deinit();
    try env.put("LWS_BIN_DIR", dir_path);

    const res = try resolve(allocator, io, &env, "sqs", "lws-sqs");
    defer allocator.free(res.path);
    try std.testing.expectEqual(Source.env, res.source);
    try std.testing.expect(std.mem.endsWith(u8, res.path, "lws-sqs"));
}
