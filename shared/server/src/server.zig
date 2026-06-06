const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const http = std.http;

pub const Method = http.Method;
pub const Status = http.Status;
pub const Header = http.Header;
pub const RespondOptions = http.Server.Request.RespondOptions;

pub const Options = struct {
    port: u16,
    host: []const u8 = "127.0.0.1",
    header_buffer_size: usize = 16 * 1024,
    write_buffer_size: usize = 16 * 1024,
    max_body_size: usize = 8 * 1024 * 1024,
};

pub const Handler = *const fn (ctx: *Context) anyerror!void;

pub const Server = struct {
    io: Io,
    gpa: std.mem.Allocator,
    net_server: net.Server,
    opts: Options,

    pub fn init(io: Io, gpa: std.mem.Allocator, opts: Options) !Server {
        const addr = try net.IpAddress.parse(opts.host, opts.port);
        const net_server = try addr.listen(io, .{ .reuse_address = true });
        return .{ .io = io, .gpa = gpa, .net_server = net_server, .opts = opts };
    }

    pub fn deinit(self: *Server) void {
        self.net_server.deinit(self.io);
    }

    pub fn run(self: *Server, handler: Handler, user: ?*anyopaque) !void {
        while (true) {
            const stream = self.net_server.accept(self.io) catch |err| switch (err) {
                error.ConnectionAborted, error.WouldBlock => continue,
                else => return err,
            };
            const args = self.gpa.create(ConnArgs) catch {
                self.handleConnection(stream, handler, user) catch {};
                continue;
            };
            args.* = .{ .self = self, .stream = stream, .handler = handler, .user = user };
            const t = std.Thread.spawn(.{}, runConn, .{args}) catch {
                self.handleConnection(stream, handler, user) catch {};
                self.gpa.destroy(args);
                continue;
            };
            t.detach();
        }
    }

    const ConnArgs = struct {
        self: *Server,
        stream: net.Stream,
        handler: Handler,
        user: ?*anyopaque,
    };

    fn runConn(args: *ConnArgs) void {
        defer args.self.gpa.destroy(args);
        args.self.handleConnection(args.stream, args.handler, args.user) catch {};
    }

    fn handleConnection(self: *Server, stream: net.Stream, handler: Handler, user: ?*anyopaque) !void {
        defer stream.close(self.io);

        const read_buf = try self.gpa.alloc(u8, self.opts.header_buffer_size);
        defer self.gpa.free(read_buf);
        const write_buf = try self.gpa.alloc(u8, self.opts.write_buffer_size);
        defer self.gpa.free(write_buf);

        var conn_reader = stream.reader(self.io, read_buf);
        var conn_writer = stream.writer(self.io, write_buf);

        var srv = http.Server.init(&conn_reader.interface, &conn_writer.interface);

        while (true) {
            var request = srv.receiveHead() catch return;

            var ctx: Context = .{
                .request = &request,
                .gpa = self.gpa,
                .io = self.io,
                .max_body_size = self.opts.max_body_size,
                .user = user,
            };

            handler(&ctx) catch {
                if (!ctx.responded) ctx.text(.internal_server_error, "internal error") catch return;
            };

            if (!ctx.responded) ctx.text(.not_found, "not found") catch return;

            if (srv.reader.state != .ready) return;
        }
    }
};

pub const Context = struct {
    request: *http.Server.Request,
    gpa: std.mem.Allocator,
    io: Io,
    max_body_size: usize,
    user: ?*anyopaque,
    responded: bool = false,

    pub fn method(self: *Context) Method {
        return self.request.head.method;
    }

    pub fn target(self: *Context) []const u8 {
        return self.request.head.target;
    }

    pub fn path(self: *Context) []const u8 {
        const t = self.request.head.target;
        if (std.mem.indexOfScalar(u8, t, '?')) |i| return t[0..i];
        return t;
    }

    pub fn query(self: *Context) ?[]const u8 {
        const t = self.request.head.target;
        if (std.mem.indexOfScalar(u8, t, '?')) |i| return t[i + 1 ..];
        return null;
    }

    pub fn header(self: *Context, name: []const u8) ?[]const u8 {
        var it = self.request.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn userData(self: *Context, comptime T: type) *T {
        return @ptrCast(@alignCast(self.user.?));
    }

    pub fn readBody(self: *Context) ![]u8 {
        var buf: [4096]u8 = undefined;
        const reader = try self.request.readerExpectContinue(&buf);
        return reader.allocRemaining(self.gpa, Io.Limit.limited(self.max_body_size));
    }

    pub fn respond(self: *Context, content: []const u8, opts: RespondOptions) !void {
        try self.request.respond(content, opts);
        self.responded = true;
    }

    pub fn text(self: *Context, status: Status, body: []const u8) !void {
        try self.respond(body, .{
            .status = status,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
    }

    pub fn json(self: *Context, status: Status, body: []const u8) !void {
        try self.respond(body, .{
            .status = status,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }
};

test "path and query split target" {
    var head: http.Server.Request.Head = undefined;
    head.method = .GET;
    head.target = "/queue?foo=bar";
    var req: http.Server.Request = .{ .server = undefined, .head = head, .head_buffer = "" };
    var ctx: Context = .{
        .request = &req,
        .gpa = std.testing.allocator,
        .io = undefined,
        .max_body_size = 0,
        .user = null,
    };
    try std.testing.expectEqualStrings("/queue", ctx.path());
    try std.testing.expectEqualStrings("foo=bar", ctx.query().?);
}
