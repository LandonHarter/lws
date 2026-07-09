const std = @import("std");

pub const Tools = struct {
    initdb: []const u8,
    postgres: []const u8,
    psql: ?[]const u8,
};

pub const Error = error{PostgresNotFound} || std.mem.Allocator.Error;

const extra_dirs = [_][]const u8{
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/lib/postgresql",
    "/usr/pgsql",
    "/Library/PostgreSQL",
    "/usr/bin",
};

pub fn resolve(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) Error!Tools {
    return resolveIn(arena, io, env, &extra_dirs);
}

fn resolveIn(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, dirs: []const []const u8) Error!Tools {
    const initdb = (try whichIn(arena, io, env, dirs, "initdb")) orelse return Error.PostgresNotFound;
    const postgres = (try whichIn(arena, io, env, dirs, "postgres")) orelse return Error.PostgresNotFound;
    const psql = try whichIn(arena, io, env, dirs, "psql");
    return .{ .initdb = initdb, .postgres = postgres, .psql = psql };
}

fn probe(arena: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) !?[]const u8 {
    const candidate = try std.fs.path.join(arena, &.{ dir, name });
    std.Io.Dir.accessAbsolute(io, candidate, .{}) catch return null;
    return candidate;
}

fn which(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) !?[]const u8 {
    return whichIn(arena, io, env, &extra_dirs, name);
}

fn whichIn(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, dirs: []const []const u8, name: []const u8) !?[]const u8 {
    if (env.get("PATH")) |path| {
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            if (try probe(arena, io, dir, name)) |hit| return hit;
        }
    }

    for (dirs) |dir| {
        if (try probe(arena, io, dir, name)) |hit| return hit;

        var root = std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true }) catch continue;
        defer root.close(io);
        var rit = root.iterate();
        while (rit.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const bin = try std.fs.path.join(arena, &.{ dir, entry.name, "bin" });
            if (try probe(arena, io, bin, name)) |hit| return hit;
        }
    }

    return null;
}

pub const install_guidance =
    \\PostgreSQL is required but was not found on your PATH.
    \\Install it, then try again:
    \\  macOS (Homebrew):   brew install postgresql@16
    \\  Debian/Ubuntu:      sudo apt-get install -y postgresql
    \\  Fedora/RHEL:        sudo dnf install -y postgresql-server
    \\  Arch:               sudo pacman -S postgresql
    \\After installing, make sure `initdb` and `postgres` are on your PATH.
    \\(Homebrew: export PATH="$(brew --prefix postgresql@16)/bin:$PATH")
    \\
;

pub fn printGuidance(w: *std.Io.Writer) !void {
    try w.writeAll(install_guidance);
}

const testing = std.testing;

test "which finds a tool on PATH" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/nonexistent:/bin");

    const found = try which(arena, testing.io, &env, "sh");
    try testing.expect(found != null);
    try testing.expect(std.mem.endsWith(u8, found.?, "/sh"));
}

test "which returns null for a nonsense name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/bin:/usr/bin");

    const found = try which(arena, testing.io, &env, "definitely-not-a-real-binary-xyzzy");
    try testing.expect(found == null);
}

test "resolve surfaces PostgresNotFound when nothing is found" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/nonexistent-a:/nonexistent-b");

    const empty_dirs = [_][]const u8{"/nonexistent-c"};
    try testing.expectError(Error.PostgresNotFound, resolveIn(arena, testing.io, &env, &empty_dirs));
}
