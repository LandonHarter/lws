const std = @import("std");
const builtin = @import("builtin");
const zli = @import("zli");

const root_dir = @import("../core/root_dir.zig");

const EnvMap = std.process.Environ.Map;

const port_flag = zli.Flag{
    .name = "port",
    .shortcut = "p",
    .description = "Port to bind the dashboard to",
    .type = .Int,
    .default_value = .{ .Int = 3000 },
};

const no_open_flag = zli.Flag{
    .name = "no-open",
    .description = "Do not open the dashboard in your browser",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "dash",
        .description = "Launch the LWS dashboard",
    }, run);
    try cmd.addFlag(port_flag);
    try cmd.addFlag(no_open_flag);
    return cmd;
}

fn run(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const out = ctx.writer;
    const env_map: ?*const EnvMap = if (ctx.data) |d| @ptrCast(@alignCast(d)) else null;

    const port: u16 = @intCast(ctx.flag("port", i32));
    const open_browser = !ctx.flag("no-open", bool);

    const server_path = try resolveDashServer(allocator, io, env_map) orelse {
        try out.print(
            "could not find bundled dashboard. Tried: $LWS_DASH_DIR, <install>/share/lws/dash, ./dash/dist. " ++
                "If you installed lws, reinstall. If you're on the source tree, run `cd dash && bun run bundle`.\n",
            .{},
        );
        try out.flush();
        std.process.exit(1);
    };
    defer allocator.free(server_path);

    const dash_dir = std.fs.path.dirname(server_path) orelse ".";

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_str);

    var child_env = EnvMap.init(allocator);
    defer child_env.deinit();
    if (env_map) |m| {
        for (m.keys(), m.values()) |k, v| try child_env.put(k, v);
    }
    try child_env.put("PORT", port_str);
    try child_env.put("LWS_ROOT", cwd);
    if (!child_env.contains("LWS_BIN")) {
        if (std.process.executablePathAlloc(io, allocator)) |self_exe| {
            defer allocator.free(self_exe);
            try child_env.put("LWS_BIN", self_exe);
        } else |_| {}
    }

    try out.print("starting dashboard…\n", .{});
    try out.flush();

    var child = std.process.spawn(io, .{
        .argv = &.{ "node", "server.js" },
        .cwd = .{ .path = dash_dir },
        .environ_map = &child_env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try out.print("node not found on PATH. Install Node 20+ to use the dashboard.\n", .{});
            try out.flush();
            std.process.exit(1);
        },
        else => return err,
    };

    try out.print("dashboard listening on http://localhost:{d}\n", .{port});
    try out.flush();

    if (open_browser and !isSshSession(env_map)) {
        if (waitForServer(io, port)) {
            openBrowser(allocator, io, port) catch {};
        }
    }

    _ = child.wait(io) catch {};
}

fn resolveDashServer(allocator: std.mem.Allocator, io: std.Io, env_map: ?*const EnvMap) !?[]u8 {
    if (env_map) |m| {
        if (m.get("LWS_DASH_DIR")) |dir| {
            if (dir.len > 0) {
                if (try fileIn(allocator, io, dir, "server.js")) |path| return path;
            }
        }
    }

    if (std.process.executableDirPathAlloc(io, allocator)) |self_dir| {
        defer allocator.free(self_dir);
        const dir = try std.fs.path.join(allocator, &.{ self_dir, "..", "share", "lws", "dash" });
        defer allocator.free(dir);
        if (try fileIn(allocator, io, dir, "server.js")) |path| return path;
    } else |_| {}

    if (root_dir.find(allocator, io)) |root| {
        defer allocator.free(root);
        const dir = try std.fs.path.join(allocator, &.{ root, "dash", "dist" });
        defer allocator.free(dir);
        if (try fileIn(allocator, io, dir, "server.js")) |path| return path;
    } else |_| {}

    return null;
}

fn fileIn(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) std.mem.Allocator.Error!?[]u8 {
    const candidate = try std.fs.path.join(allocator, &.{ dir, name });
    std.Io.Dir.accessAbsolute(io, candidate, .{}) catch {
        allocator.free(candidate);
        return null;
    };
    return candidate;
}

fn waitForServer(io: std.Io, port: u16) bool {
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return false;
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        if (addr.connect(io, .{ .mode = .stream })) |stream| {
            var s = stream;
            s.close(io);
            return true;
        } else |_| {}
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch return false;
    }
    return false;
}

fn isSshSession(env_map: ?*const EnvMap) bool {
    if (env_map) |m| {
        if (m.get("SSH_CONNECTION")) |v| return v.len > 0;
    }
    return false;
}

fn openBrowser(allocator: std.mem.Allocator, io: std.Io, port: u16) !void {
    const url = try std.fmt.allocPrint(allocator, "http://localhost:{d}", .{port});
    defer allocator.free(url);

    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => &.{ "xdg-open", url },
    };

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = child.wait(io) catch {};
}

test "fileIn returns path when file present" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "server.js", .data = "" });

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const dir_path = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(dir_path);

    const found = try fileIn(allocator, io, dir_path, "server.js");
    defer if (found) |f| allocator.free(f);
    try std.testing.expect(found != null);
    try std.testing.expect(std.mem.endsWith(u8, found.?, "server.js"));
}

test "fileIn returns null when file absent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const dir_path = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(dir_path);

    const found = try fileIn(allocator, io, dir_path, "server.js");
    try std.testing.expect(found == null);
}
