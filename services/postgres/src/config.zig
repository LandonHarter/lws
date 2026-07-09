const std = @import("std");

pub const Config = struct {
    databases: []const []const u8 = &.{},
    seed_sql: ?[]const u8 = null,
};

pub const LoadError = error{
    InvalidConfig,
} || std.mem.Allocator.Error || std.Io.Dir.ReadFileAllocError || std.json.ParseError(std.json.Scanner);

const max_config_bytes = 4 * 1024 * 1024;

pub fn writeDefaults(w: *std.Io.Writer) !void {
    try w.writeAll("{\"databases\":[],\"seed_sql\":null}\n");
}

pub fn loadFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!Config {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, std.Io.Limit.limited(max_config_bytes));
    return loadBytes(arena, bytes);
}

pub fn loadBytes(arena: std.mem.Allocator, bytes: []const u8) LoadError!Config {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (root != .object) {
        std.debug.print("postgres config: top-level value must be an object\n", .{});
        return LoadError.InvalidConfig;
    }
    const obj = root.object;

    var cfg: Config = .{};

    if (obj.get("databases")) |dbs| {
        if (dbs != .array) {
            std.debug.print("postgres config: 'databases' must be an array of strings\n", .{});
            return LoadError.InvalidConfig;
        }
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (dbs.array.items) |item| {
            if (item != .string) {
                std.debug.print("postgres config: 'databases' entries must be strings\n", .{});
                return LoadError.InvalidConfig;
            }
            try list.append(arena, item.string);
        }
        cfg.databases = try list.toOwnedSlice(arena);
    }

    if (obj.get("seed_sql")) |seed| {
        switch (seed) {
            .string => |s| cfg.seed_sql = s,
            .null => cfg.seed_sql = null,
            else => {
                std.debug.print("postgres config: 'seed_sql' must be a string or null\n", .{});
                return LoadError.InvalidConfig;
            },
        }
    }

    return cfg;
}

const testing = std.testing;

test "empty object yields defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const cfg = try loadBytes(arena_state.allocator(), "{}");
    try testing.expectEqual(@as(usize, 0), cfg.databases.len);
    try testing.expect(cfg.seed_sql == null);
}

test "parses databases and seed_sql" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const cfg = try loadBytes(arena_state.allocator(),
        \\{ "databases": ["appdb", "analytics"], "seed_sql": "create table t(id int);" }
    );
    try testing.expectEqual(@as(usize, 2), cfg.databases.len);
    try testing.expectEqualStrings("appdb", cfg.databases[0]);
    try testing.expectEqualStrings("analytics", cfg.databases[1]);
    try testing.expectEqualStrings("create table t(id int);", cfg.seed_sql.?);
}

test "non-object top level rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(LoadError.InvalidConfig, loadBytes(arena_state.allocator(), "[]"));
}

test "databases must be array of strings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(LoadError.InvalidConfig, loadBytes(arena_state.allocator(), "{ \"databases\": [1, 2] }"));
}
