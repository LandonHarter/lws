const std = @import("std");
const zli = @import("zli");
const build_options = @import("build_options");

const EnvMap = std.process.Environ.Map;

const default_repo = "LandonHarter/lws";

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    return zli.Command.init(init_options, .{
        .name = "update",
        .description = "Update lws to the latest release",
    }, run);
}

fn run(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const out = ctx.writer;
    const env_map: ?*const EnvMap = if (ctx.data) |d| @ptrCast(@alignCast(d)) else null;

    const repo = envOr(env_map, "LWS_REPO", default_repo);
    const current = build_options.version;

    const latest = resolveLatest(allocator, io, repo) catch |err| {
        try out.print("could not check for updates: {s}\n", .{@errorName(err)});
        try out.flush();
        std.process.exit(1);
    };
    defer allocator.free(latest);

    if (std.mem.eql(u8, latest, current)) {
        try out.print("already on the latest version ({s})\n", .{current});
        try out.flush();
        return;
    }

    try out.print("updating lws {s} -> {s}\n", .{ current, latest });
    try out.flush();

    const script_url = try std.fmt.allocPrint(
        allocator,
        "https://raw.githubusercontent.com/{s}/master/install.sh",
        .{repo},
    );
    defer allocator.free(script_url);

    const pipeline = try std.fmt.allocPrint(allocator, "curl -fsSL {s} | sh", .{script_url});
    defer allocator.free(pipeline);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", pipeline },
        .cwd = .inherit,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) {
            try out.print("install script failed (exit {d})\n", .{code});
            try out.flush();
            std.process.exit(code);
        },
        else => {
            try out.print("install script terminated abnormally\n", .{});
            try out.flush();
            std.process.exit(1);
        },
    }
}

fn resolveLatest(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) ![]u8 {
    const api_url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/releases/latest",
        .{repo},
    );
    defer allocator.free(api_url);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-fsSL", api_url },
        .stdout_limit = .limited(1 << 20),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.CurlFailed,
        else => return error.CurlFailed,
    }

    const tag = parseTag(result.stdout) orelse return error.NoReleaseFound;
    return allocator.dupe(u8, tag);
}

// Extracts the semver from a GitHub releases JSON body, stripping the leading
// "v" from the tag (e.g. "tag_name": "v0.1.0" -> "0.1.0").
fn parseTag(body: []const u8) ?[]const u8 {
    const key = "\"tag_name\"";
    const key_at = std.mem.indexOf(u8, body, key) orelse return null;
    var i = key_at + key.len;

    while (i < body.len and body[i] != ':') : (i += 1) {}
    while (i < body.len and body[i] != '"') : (i += 1) {}
    if (i >= body.len) return null;
    i += 1;

    if (i < body.len and body[i] == 'v') i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {}
    if (i >= body.len) return null;

    return body[start..i];
}

fn envOr(env_map: ?*const EnvMap, key: []const u8, fallback: []const u8) []const u8 {
    if (env_map) |m| {
        if (m.get(key)) |v| {
            if (v.len > 0) return v;
        }
    }
    return fallback;
}

test "parseTag strips leading v" {
    const body = "{\"url\":\"x\",\"tag_name\": \"v1.2.3\",\"name\":\"y\"}";
    try std.testing.expectEqualStrings("1.2.3", parseTag(body).?);
}

test "parseTag without v prefix" {
    const body = "{\"tag_name\":\"0.9.0\"}";
    try std.testing.expectEqualStrings("0.9.0", parseTag(body).?);
}

test "parseTag missing key" {
    try std.testing.expect(parseTag("{\"name\":\"x\"}") == null);
}
