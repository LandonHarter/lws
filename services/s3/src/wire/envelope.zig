const std = @import("std");
const server = @import("server");
const id = @import("core").id;
const bucket_dir = @import("../persist/bucket_dir.zig");
const chunked = @import("chunked.zig");
const Runtime = @import("../runtime.zig").Runtime;

pub const Addressing = enum { path_style, virtual_host };

pub const Scope = enum { service, bucket, object };

pub const Subresource = enum {
    none,
    uploads,
    upload_id,
    delete,
    location,
    versioning,
    acl,
    policy,
    tagging,
    cors,
    lifecycle,
    website,
    notification,
    encryption,
    logging,
    accelerate,
    request_payment,
    public_access_block,
    ownership_controls,
    replication,
    object_lock,
    metrics,
    inventory,
    analytics,
    intelligent_tiering,
    attributes,
    retention,
    legal_hold,
    list_v2,
    list_v1,
    list_uploads,
};

pub const QPair = struct { key: []const u8, value: []const u8 };

pub const QueryMap = struct {
    items: []const QPair = &.{},

    pub fn get(self: QueryMap, name: []const u8) ?[]const u8 {
        for (self.items) |p| if (std.mem.eql(u8, p.key, name)) return p.value;
        return null;
    }

    pub fn has(self: QueryMap, name: []const u8) bool {
        return self.get(name) != null;
    }
};

pub const HeaderView = struct {
    items: []const std.http.Header = &.{},

    pub fn get(self: HeaderView, name: []const u8) ?[]const u8 {
        for (self.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

pub const Request = struct {
    method: std.http.Method,
    scope: Scope,
    addressing: Addressing,
    bucket: ?[]const u8,
    key: ?[]const u8,
    subresource: Subresource,
    query: QueryMap,
    headers: HeaderView,
    request_id: [36]u8,
    authorization: []const u8,
    content_sha256: []const u8,
    is_chunked: bool,
    body: []u8,
    arena: *std.heap.ArenaAllocator,
};

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// Percent-decode. `plus_as_space` is true for query components (application
// of the form-encoding rule) and false for path segments where '+' is literal.
pub fn percentDecode(arena: std.mem.Allocator, s: []const u8, plus_as_space: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '+' and plus_as_space) {
            try out.append(arena, ' ');
            i += 1;
        } else if (c == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                try out.append(arena, (hi.? << 4) | lo.?);
                i += 3;
            } else {
                try out.append(arena, c);
                i += 1;
            }
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return out.items;
}

// Decode a key path: split on '/', decode each segment, rejoin. Preserves
// embedded and trailing slashes; '+' is literal.
fn decodePath(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '/');
    var first = true;
    while (it.next()) |seg| {
        if (!first) try out.append(arena, '/');
        first = false;
        try out.appendSlice(arena, try percentDecode(arena, seg, false));
    }
    return out.items;
}

fn stripPort(h: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, h, ':')) |i| return h[0..i];
    return h;
}

fn isValidBucketLabel(s: []const u8) bool {
    bucket_dir.validateName(s) catch return false;
    return true;
}

pub const AddrResult = struct { addressing: Addressing, bucket: ?[]const u8 };

pub fn classifyAddressing(host_header: []const u8, rt_host: []const u8) AddrResult {
    const host = stripPort(host_header);
    const expected = stripPort(rt_host);
    if (expected.len > 0 and host.len > expected.len + 1 and std.mem.endsWith(u8, host, expected)) {
        const dot = host.len - expected.len - 1;
        const candidate = host[0..dot];
        if (host[dot] == '.' and isValidBucketLabel(candidate)) {
            return .{ .addressing = .virtual_host, .bucket = candidate };
        }
    }
    return .{ .addressing = .path_style, .bucket = null };
}

pub const PathParts = struct { scope: Scope, bucket: ?[]const u8, key: ?[]const u8 };

pub fn parsePath(
    arena: std.mem.Allocator,
    path: []const u8,
    addressing: Addressing,
    host_bucket: ?[]const u8,
) !PathParts {
    const p = if (path.len > 0 and path[0] == '/') path[1..] else path;
    switch (addressing) {
        .virtual_host => {
            if (p.len == 0) return .{ .scope = .bucket, .bucket = host_bucket, .key = null };
            return .{ .scope = .object, .bucket = host_bucket, .key = try decodePath(arena, p) };
        },
        .path_style => {
            if (p.len == 0) return .{ .scope = .service, .bucket = null, .key = null };
            const slash = std.mem.indexOfScalar(u8, p, '/');
            if (slash == null) {
                return .{ .scope = .bucket, .bucket = try percentDecode(arena, p, false), .key = null };
            }
            const b = try percentDecode(arena, p[0..slash.?], false);
            const rest = p[slash.? + 1 ..];
            if (rest.len == 0) return .{ .scope = .bucket, .bucket = b, .key = null };
            return .{ .scope = .object, .bucket = b, .key = try decodePath(arena, rest) };
        },
    }
}

pub fn parseQuery(arena: std.mem.Allocator, raw: []const u8) !QueryMap {
    var out: std.ArrayList(QPair) = .empty;
    var it = std.mem.splitScalar(u8, raw, '&');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (std.mem.indexOfScalar(u8, seg, '=')) |eq| {
            try out.append(arena, .{
                .key = try percentDecode(arena, seg[0..eq], true),
                .value = try percentDecode(arena, seg[eq + 1 ..], true),
            });
        } else {
            try out.append(arena, .{ .key = try percentDecode(arena, seg, true), .value = "" });
        }
    }
    return .{ .items = out.items };
}

pub fn detectSubresource(scope: Scope, qm: QueryMap) Subresource {
    if (qm.has("delete")) return .delete;
    if (qm.has("uploads")) return if (scope == .bucket) .list_uploads else .uploads;
    if (qm.has("uploadId")) return .upload_id;
    if (qm.get("list-type")) |v| if (std.mem.eql(u8, v, "2")) return .list_v2;

    const Entry = struct { k: []const u8, s: Subresource };
    const table = [_]Entry{
        .{ .k = "location", .s = .location },
        .{ .k = "versioning", .s = .versioning },
        .{ .k = "acl", .s = .acl },
        .{ .k = "policy", .s = .policy },
        .{ .k = "tagging", .s = .tagging },
        .{ .k = "cors", .s = .cors },
        .{ .k = "lifecycle", .s = .lifecycle },
        .{ .k = "website", .s = .website },
        .{ .k = "notification", .s = .notification },
        .{ .k = "encryption", .s = .encryption },
        .{ .k = "logging", .s = .logging },
        .{ .k = "accelerate", .s = .accelerate },
        .{ .k = "requestPayment", .s = .request_payment },
        .{ .k = "publicAccessBlock", .s = .public_access_block },
        .{ .k = "ownershipControls", .s = .ownership_controls },
        .{ .k = "replication", .s = .replication },
        .{ .k = "object-lock", .s = .object_lock },
        .{ .k = "metrics", .s = .metrics },
        .{ .k = "inventory", .s = .inventory },
        .{ .k = "analytics", .s = .analytics },
        .{ .k = "intelligent-tiering", .s = .intelligent_tiering },
        .{ .k = "attributes", .s = .attributes },
        .{ .k = "retention", .s = .retention },
        .{ .k = "legal-hold", .s = .legal_hold },
    };
    for (table) |e| if (qm.has(e.k)) return e.s;
    return .none;
}

pub fn parse(arena: *std.heap.ArenaAllocator, ctx: *server.Context, rt: *Runtime) !Request {
    const a = arena.allocator();

    // All header reads must precede readBody: consuming the body advances the
    // HTTP reader past received_head, after which iterateHeaders panics.
    var hlist: std.ArrayList(std.http.Header) = .empty;
    var it = ctx.request.iterateHeaders();
    while (it.next()) |h| {
        try hlist.append(a, .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) });
    }
    const headers: HeaderView = .{ .items = hlist.items };

    const authorization = headers.get("authorization") orelse "";
    const content_sha256 = headers.get("x-amz-content-sha256") orelse "";
    const host_header = headers.get("host") orelse "";

    const qm = try parseQuery(a, ctx.query() orelse "");

    const auth_ok = std.mem.startsWith(u8, authorization, "AWS4-HMAC-SHA256") or qm.has("X-Amz-Signature");
    if (!auth_ok) return error.MissingAuth;

    const addr = classifyAddressing(host_header, rt.host);
    const pp = try parsePath(a, ctx.path(), addr.addressing, addr.bucket);
    const subres = detectSubresource(pp.scope, qm);

    const is_chunked = std.mem.startsWith(u8, content_sha256, "STREAMING-");

    const body = try ctx.readBody();
    const body_dup = try a.dupe(u8, body);
    ctx.gpa.free(body);
    const final_body = if (is_chunked) try chunked.decode(a, body_dup) else body_dup;

    var req: Request = .{
        .method = ctx.method(),
        .scope = pp.scope,
        .addressing = addr.addressing,
        .bucket = pp.bucket,
        .key = pp.key,
        .subresource = subres,
        .query = qm,
        .headers = headers,
        .request_id = undefined,
        .authorization = authorization,
        .content_sha256 = content_sha256,
        .is_chunked = is_chunked,
        .body = final_body,
        .arena = arena,
    };
    id.uuidV4(rt.rng, &req.request_id);
    return req;
}

const testing = std.testing;

test "classifyAddressing path vs virtual" {
    const a = classifyAddressing("127.0.0.1:9000", "127.0.0.1:9000");
    try testing.expectEqual(Addressing.path_style, a.addressing);
    try testing.expect(a.bucket == null);

    const v = classifyAddressing("my-bucket.localhost:9000", "localhost:9000");
    try testing.expectEqual(Addressing.virtual_host, v.addressing);
    try testing.expectEqualStrings("my-bucket", v.bucket.?);

    // invalid label (too short) falls back to path style
    const p = classifyAddressing("ab.localhost:9000", "localhost:9000");
    try testing.expectEqual(Addressing.path_style, p.addressing);
}

test "parsePath path-style" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try parsePath(a, "/", .path_style, null);
    try testing.expectEqual(Scope.service, root.scope);

    const buck = try parsePath(a, "/foo", .path_style, null);
    try testing.expectEqual(Scope.bucket, buck.scope);
    try testing.expectEqualStrings("foo", buck.bucket.?);
    try testing.expect(buck.key == null);

    const obj = try parsePath(a, "/foo/bar/baz", .path_style, null);
    try testing.expectEqual(Scope.object, obj.scope);
    try testing.expectEqualStrings("foo", obj.bucket.?);
    try testing.expectEqualStrings("bar/baz", obj.key.?);

    const trailing = try parsePath(a, "/foo/", .path_style, null);
    try testing.expectEqual(Scope.bucket, trailing.scope);

    const dirmarker = try parsePath(a, "/foo/dir/", .path_style, null);
    try testing.expectEqual(Scope.object, dirmarker.scope);
    try testing.expectEqualStrings("dir/", dirmarker.key.?);
}

test "parsePath virtual-host and percent decode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const obj = try parsePath(a, "/bar/baz", .virtual_host, "foo");
    try testing.expectEqual(Scope.object, obj.scope);
    try testing.expectEqualStrings("foo", obj.bucket.?);
    try testing.expectEqualStrings("bar/baz", obj.key.?);

    const only = try parsePath(a, "/", .virtual_host, "foo");
    try testing.expectEqual(Scope.bucket, only.scope);

    const enc = try parsePath(a, "/foo/my%20key/a%2Bb", .path_style, null);
    try testing.expectEqualStrings("foo", enc.bucket.?);
    try testing.expectEqualStrings("my key/a+b", enc.key.?);
}

test "parseQuery decodes and splits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const qm = try parseQuery(arena.allocator(), "list-type=2&prefix=foo%2F&delimiter=%2F&fetch-owner");
    try testing.expectEqualStrings("2", qm.get("list-type").?);
    try testing.expectEqualStrings("foo/", qm.get("prefix").?);
    try testing.expectEqualStrings("/", qm.get("delimiter").?);
    try testing.expect(qm.has("fetch-owner"));
    try testing.expect(!qm.has("missing"));
}

test "detectSubresource precedence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(Subresource.delete, detectSubresource(.bucket, try parseQuery(a, "delete")));
    try testing.expectEqual(Subresource.uploads, detectSubresource(.object, try parseQuery(a, "uploads")));
    try testing.expectEqual(Subresource.list_uploads, detectSubresource(.bucket, try parseQuery(a, "uploads")));
    try testing.expectEqual(Subresource.upload_id, detectSubresource(.object, try parseQuery(a, "uploadId=abc&partNumber=1")));
    try testing.expectEqual(Subresource.list_v2, detectSubresource(.bucket, try parseQuery(a, "list-type=2")));
    try testing.expectEqual(Subresource.acl, detectSubresource(.bucket, try parseQuery(a, "acl")));
    // delete wins over a group-5 flag
    try testing.expectEqual(Subresource.delete, detectSubresource(.bucket, try parseQuery(a, "tagging&delete")));
    try testing.expectEqual(Subresource.none, detectSubresource(.bucket, try parseQuery(a, "prefix=x")));
}
