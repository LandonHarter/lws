const std = @import("std");
const log = @import("core").log;
const deps = @import("deps.zig");
const pg = @import("pg.zig");
const config = @import("config.zig");

const Config = struct {
    port: u16 = 5432,
    bind: []const u8 = "127.0.0.1",
    data_dir: []const u8 = ".lws/postgres",
    config_path: []const u8 = "",
    generate_config: bool = false,
    check_deps: bool = false,
    log_level: []const u8 = "info",
};

var child_pid = std.atomic.Value(std.posix.pid_t).init(-1);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    const pid = child_pid.load(.seq_cst);
    if (pid > 0) {
        // Postgres fast shutdown: disconnect clients, roll back open txns, exit
        // cleanly. SIGTERM would be smart shutdown, which hangs on idle pooled conns.
        std.posix.kill(pid, .INT) catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();

    var cfg: Config = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args.next() orelse return error.MissingPortValue;
            cfg.port = try std.fmt.parseInt(u16, val, 10);
        } else if (std.mem.eql(u8, arg, "--bind")) {
            cfg.bind = args.next() orelse return error.MissingBindValue;
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            cfg.data_dir = args.next() orelse return error.MissingDataDirValue;
        } else if (std.mem.eql(u8, arg, "--config")) {
            cfg.config_path = args.next() orelse return error.MissingConfigValue;
        } else if (std.mem.eql(u8, arg, "--generate-config")) {
            cfg.generate_config = true;
        } else if (std.mem.eql(u8, arg, "--check-deps")) {
            cfg.check_deps = true;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            cfg.log_level = args.next() orelse return error.MissingLogLevelValue;
        } else {
            std.debug.print("postgres: unknown arg '{s}'\n", .{arg});
            return error.UnknownArg;
        }
    }

    if (cfg.generate_config) {
        var wbuf: [256]u8 = undefined;
        var stdout_writer = std.Io.File.Writer.init(.stdout(), init.io, &wbuf);
        const stdout = &stdout_writer.interface;
        try config.writeDefaults(stdout);
        try stdout.flush();
        return;
    }

    if (log.Level.parse(cfg.log_level) == null) {
        std.debug.print("postgres: invalid --log-level '{s}' (want error|warn|info|debug)\n", .{cfg.log_level});
        return error.InvalidLogLevel;
    }

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const tools = deps.resolve(a, init.io, init.environ_map) catch |err| switch (err) {
        deps.Error.PostgresNotFound => {
            var ebuf: [1024]u8 = undefined;
            var stderr_writer = std.Io.File.Writer.init(.stderr(), init.io, &ebuf);
            const stderr = &stderr_writer.interface;
            try deps.printGuidance(stderr);
            try stderr.flush();
            return error.PostgresNotFound;
        },
        else => return err,
    };

    if (cfg.check_deps) {
        if (tools.psql) |psql| {
            std.debug.print("postgres: found initdb at {s}, postgres at {s}, psql at {s}\n", .{ tools.initdb, tools.postgres, psql });
        } else {
            std.debug.print("postgres: found initdb at {s}, postgres at {s} (psql not found — seeding disabled)\n", .{ tools.initdb, tools.postgres });
        }
        return;
    }

    var cfg_data: config.Config = .{};
    if (cfg.config_path.len > 0) {
        cfg_data = config.loadFile(a, init.io, cfg.config_path) catch |err| {
            std.debug.print("postgres: failed to load config '{s}': {s}\n", .{ cfg.config_path, @errorName(err) });
            return err;
        };
    }

    try std.Io.Dir.createDirPath(.cwd(), init.io, cfg.data_dir);
    const pgdata = try std.fs.path.join(a, &.{ cfg.data_dir, "pgdata" });

    var cluster: pg.Cluster = .{
        .tools = tools,
        .data_dir = cfg.data_dir,
        .pgdata = pgdata,
        .port = cfg.port,
        .bind = cfg.bind,
        .io = init.io,
        .gpa = init.gpa,
    };

    if (!cluster.isInitialized()) {
        try cluster.initCluster();
    } else {
        std.debug.print("postgres: cluster already initialized at {s}\n", .{pgdata});
    }

    var act = std.posix.Sigaction{
        .handler = .{ .handler = &onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.INT, &act, null);

    var child = try cluster.start();
    child_pid.store(child.id orelse return error.SpawnFailed, .seq_cst);

    cluster.waitReady(30_000) catch |err| {
        std.debug.print("postgres: readiness wait did not complete ({s}); continuing\n", .{@errorName(err)});
    };

    for (cfg_data.databases) |db| {
        createDatabase(tools, init.io, init.gpa, cfg.data_dir, cfg.port, db) catch |err| {
            std.debug.print("postgres: createDatabase '{s}' failed: {s}\n", .{ db, @errorName(err) });
        };
    }

    if (cfg_data.seed_sql) |seed| {
        const target = if (cfg_data.databases.len > 0) cfg_data.databases[0] else "postgres";
        applySeed(tools, init.io, init.gpa, cfg.data_dir, cfg.port, seed, target) catch |err| {
            std.debug.print("postgres: applySeed failed: {s}\n", .{@errorName(err)});
        };
    }

    const term = try child.wait(init.io);
    child_pid.store(-1, .seq_cst);

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("postgres: server exited with code {d}\n", .{code});
                return error.PostgresExited;
            }
        },
        .signal => |sig| {
            std.debug.print("postgres: server terminated by signal {d}\n", .{@intFromEnum(sig)});
        },
        else => return error.PostgresTerminated,
    }
}

fn createDatabase(
    tools: deps.Tools,
    io: std.Io,
    gpa: std.mem.Allocator,
    data_dir: []const u8,
    port: u16,
    name: []const u8,
) !void {
    const psql = tools.psql orelse {
        std.debug.print("postgres: psql not found; skipping create database '{s}'\n", .{name});
        return;
    };
    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{port});
    defer gpa.free(port_str);
    const sql = try std.fmt.allocPrint(gpa, "CREATE DATABASE \"{s}\"", .{name});
    defer gpa.free(sql);

    var child = try std.process.spawn(io, .{
        .argv = &.{
            psql,
            "-h", data_dir,
            "-p", port_str,
            "-U", "postgres",
            "-d", "postgres",
            "-c", sql,
        },
        .cwd = .inherit,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        // Non-zero is tolerated: most likely the DB already exists (idempotent re-run).
        .exited => |code| if (code == 0) {
            std.debug.print("postgres: created database '{s}'\n", .{name});
        } else {
            std.debug.print("postgres: database '{s}' not created (may already exist)\n", .{name});
        },
        else => {},
    }
}

fn applySeed(
    tools: deps.Tools,
    io: std.Io,
    gpa: std.mem.Allocator,
    data_dir: []const u8,
    port: u16,
    sql_or_path: []const u8,
    db: []const u8,
) !void {
    const psql = tools.psql orelse {
        std.debug.print("postgres: psql not found; skipping seed\n", .{});
        return;
    };
    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{port});
    defer gpa.free(port_str);

    const is_file = blk: {
        std.Io.Dir.cwd().access(io, sql_or_path, .{}) catch break :blk false;
        break :blk true;
    };

    const mode_flag: []const u8 = if (is_file) "-f" else "-c";

    var child = try std.process.spawn(io, .{
        .argv = &.{
            psql,
            "-h",      data_dir,
            "-p",      port_str,
            "-U",      "postgres",
            "-d",      db,
            "-v",      "ON_ERROR_STOP=1",
            mode_flag, sql_or_path,
        },
        .cwd = .inherit,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.SeedFailed,
        else => return error.SeedFailed,
    }
    std.debug.print("postgres: applied seed SQL to database '{s}'\n", .{db});
}

test "config defaults round-trip" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try config.writeDefaults(&w);
    try std.testing.expectEqualStrings("{\"databases\":[],\"seed_sql\":null}\n", w.buffered());
}
