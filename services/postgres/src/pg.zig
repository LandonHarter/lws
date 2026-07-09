const std = @import("std");
const Tools = @import("deps.zig").Tools;

pub const Cluster = struct {
    tools: Tools,
    data_dir: []const u8,
    pgdata: []const u8,
    port: u16,
    bind: []const u8,
    io: std.Io,
    gpa: std.mem.Allocator,

    pub fn isInitialized(self: *Cluster) bool {
        const marker = std.fs.path.join(self.gpa, &.{ self.pgdata, "PG_VERSION" }) catch return false;
        defer self.gpa.free(marker);
        std.Io.Dir.cwd().access(self.io, marker, .{}) catch return false;
        return true;
    }

    pub fn initCluster(self: *Cluster) !void {
        try std.Io.Dir.createDirPath(.cwd(), self.io, self.pgdata);

        std.debug.print("postgres: initializing cluster at {s}\n", .{self.pgdata});
        var child = try std.process.spawn(self.io, .{
            // -A trust: loopback-only dev cluster; -U postgres matches the connection URL role.
            // --no-locale keeps init fast and deterministic (collation is C).
            .argv = &.{
                self.tools.initdb,
                "-D",           self.pgdata,
                "-U",           "postgres",
                "-A",           "trust",
                "--encoding=UTF8",
                "--no-locale",
            },
            .cwd = .inherit,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        const term = try child.wait(self.io);
        switch (term) {
            .exited => |code| if (code != 0) return error.InitdbFailed,
            else => return error.InitdbFailed,
        }
    }

    pub fn start(self: *Cluster) !std.process.Child {
        const port_str = try std.fmt.allocPrint(self.gpa, "{d}", .{self.port});
        defer self.gpa.free(port_str);
        const listen_opt = try std.fmt.allocPrint(self.gpa, "listen_addresses={s}", .{self.bind});
        defer self.gpa.free(listen_opt);

        std.debug.print("postgres: starting server on {s}:{d} (pgdata {s})\n", .{ self.bind, self.port, self.pgdata });
        // Unix socket lives in the instance dir (-k) to avoid /tmp perms/collisions.
        // No new process group: the supervisor is the group leader so the CLI can
        // group-kill both. listen_addresses (not -h) is the loopback bind knob.
        return std.process.spawn(self.io, .{
            .argv = &.{
                self.tools.postgres,
                "-D", self.pgdata,
                "-p", port_str,
                "-k", self.data_dir,
                "-c", listen_opt,
            },
            .cwd = .inherit,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
    }

    pub fn waitReady(self: *Cluster, timeout_ms: u64) !void {
        const psql = self.tools.psql orelse {
            std.Io.sleep(self.io, .fromMilliseconds(1500), .awake) catch {};
            return;
        };
        const port_str = try std.fmt.allocPrint(self.gpa, "{d}", .{self.port});
        defer self.gpa.free(port_str);

        const step_ms: u64 = 300;
        var waited: u64 = 0;
        while (waited < timeout_ms) {
            var child = std.process.spawn(self.io, .{
                .argv = &.{
                    psql,
                    "-h",   self.data_dir,
                    "-p",   port_str,
                    "-U",   "postgres",
                    "-d",   "postgres",
                    "-tAc", "select 1",
                },
                .cwd = .inherit,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch return error.ReadyCheckFailed;
            const term = child.wait(self.io) catch return error.ReadyCheckFailed;
            if (term == .exited and term.exited == 0) return;

            std.Io.sleep(self.io, .fromMilliseconds(step_ms), .awake) catch {};
            waited += step_ms;
        }
        return error.ReadyTimeout;
    }
};
