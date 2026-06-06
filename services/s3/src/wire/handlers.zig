const std = @import("std");
const md5 = @import("core").md5;
const idgen = @import("core").id;
const errors = @import("../errors.zig");
const envelope = @import("envelope.zig");
const headers = @import("headers.zig");
const xml = @import("xml.zig");
const bucket_dir = @import("../persist/bucket_dir.zig");
const object_dir = @import("../persist/object_dir.zig");
const upload_dir = @import("../persist/upload_dir.zig");
const object_store = @import("../store/object_store.zig");
const multipart = @import("../store/multipart.zig");
const registry_mod = @import("../registry.zig");
const Runtime = @import("../runtime.zig").Runtime;

const Request = envelope.Request;
const Bucket = registry_mod.Bucket;
const ObjectMeta = object_store.ObjectMeta;

pub const Response = struct {
    status: u16 = 200,
    headers: []const std.http.Header = &.{},
    body: []const u8 = "",
    content_type: []const u8 = "application/xml",
};

const default_max_keys: usize = 1000;
const max_object_bytes: usize = 5 * 1024 * 1024 * 1024;

// Wall-clock epoch millis. clock.nowMs() is a monotonic uptime counter, so
// object timestamps derive from nowSec() (real time) instead.
fn nowMillis(rt: *Runtime) i64 {
    return rt.clock.nowSec() * 1000;
}

// ---- helpers -------------------------------------------------------------

fn errResp(req: *Request, code: errors.Code) !Response {
    const body = try errors.render(req.arena.allocator(), code, req.bucket, null, &req.request_id);
    return .{ .status = errors.httpStatus(code), .body = body };
}

// epoch seconds -> "YYYY-MM-DDTHH:MM:SS.000Z"
fn isoTime(arena: std.mem.Allocator, epoch_secs: i64) ![]const u8 {
    const secs: u64 = if (epoch_secs < 0) 0 else @intCast(epoch_secs);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

fn quotedEtag(arena: std.mem.Allocator, etag: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "\"{s}\"", .{etag});
}

fn contentTypeOf(req: *Request) []const u8 {
    return req.headers.get("content-type") orelse "application/octet-stream";
}

// Dupe content_type + user metadata into the bucket arena so the in-memory
// object index (which never frees individual entries) keeps valid pointers.
fn collectMeta(b: *Bucket, req: *Request, key: []const u8, etag: [32]u8, size: u64, part_count: u16, now_ms: i64) !ObjectMeta {
    const ba = b.arena.allocator();
    var um: object_store.UserMeta = .empty;
    const pairs = try headers.collectUserMeta(req.arena.allocator(), req.headers.items);
    for (pairs) |p| {
        try um.put(ba, try ba.dupe(u8, p.name), try ba.dupe(u8, p.value));
    }
    return .{
        .key = key,
        .etag = etag,
        .multipart_part_count = part_count,
        .size = size,
        .content_type = try ba.dupe(u8, contentTypeOf(req)),
        .user_meta = um,
        .last_modified_ms = now_ms,
    };
}

// ---- service ops ---------------------------------------------------------

pub fn listBuckets(rt: *Runtime, req: *Request) !Response {
    const a = req.arena.allocator();
    const names = try rt.registry.listNames(a);

    var x = xml.Writer.init(a);
    try x.declaration();
    try x.openNs("ListAllMyBucketsResult", xml.s3_ns);
    try x.open("Owner");
    try x.element("ID", rt.account);
    try x.element("DisplayName", "lws");
    try x.close("Owner");
    try x.open("Buckets");
    for (names) |name| {
        const b = rt.registry.get(name) orelse continue;
        try x.open("Bucket");
        try x.element("Name", name);
        try x.element("CreationDate", try isoTime(a, b.created_at));
        try x.close("Bucket");
    }
    try x.close("Buckets");
    try x.close("ListAllMyBucketsResult");
    return .{ .body = x.finish() };
}

// ---- bucket ops ----------------------------------------------------------

pub fn createBucket(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return errResp(req, .invalid_bucket_name);
    _ = rt.registry.create(bucket, rt.region) catch |err| switch (err) {
        error.InvalidBucketName => return errResp(req, .invalid_bucket_name),
        else => return err,
    };
    const loc = try std.fmt.allocPrint(req.arena.allocator(), "/{s}", .{bucket});
    return .{ .headers = try dupHeaders(req.arena.allocator(), &.{.{ .name = "location", .value = loc }}) };
}

pub fn headBucket(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    if (rt.registry.get(bucket) == null) return .{ .status = 404 };
    return .{};
}

pub fn deleteBucket(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    rt.registry.delete(bucket) catch |err| switch (err) {
        error.NoSuchBucket => return errResp(req, .no_such_bucket),
        error.BucketNotEmpty => return errResp(req, .bucket_not_empty),
    };
    return .{ .status = 204 };
}

// ---- object ops ----------------------------------------------------------

pub fn putObject(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    const key = req.key orelse return errResp(req, .invalid_argument);
    const b = rt.registry.get(bucket) orelse return errResp(req, .no_such_bucket);

    var etag: [32]u8 = undefined;
    md5.hexLower(&etag, req.body);

    b.mutex.lockUncancelable(rt.io);
    defer b.mutex.unlock(rt.io);

    const a = req.arena.allocator();
    const odir = try object_dir.ensureDir(a, rt.io, b.dir, key);
    try object_dir.writeData(a, rt.io, odir, req.body, rt.fsync);

    const ba = b.arena.allocator();
    const owned_key = try ba.dupe(u8, key);
    const meta = try collectMeta(b, req, owned_key, etag, req.body.len, 0, nowMillis(rt));
    try object_dir.writeMeta(a, rt.io, odir, meta, rt.fsync);
    try b.object_index.put(meta);

    return .{ .headers = try dupHeaders(a, &.{.{ .name = "etag", .value = try quotedEtag(a, &etag) }}) };
}

pub fn getObject(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    const key = req.key orelse return errResp(req, .no_such_key);
    const b = rt.registry.get(bucket) orelse return errResp(req, .no_such_bucket);

    b.mutex.lockUncancelable(rt.io);
    defer b.mutex.unlock(rt.io);

    const meta = b.object_index.get(key) orelse return errResp(req, .no_such_key);
    const a = req.arena.allocator();
    const odir = try object_dir.objectDir(a, b.dir, key);
    const data = try object_dir.readData(a, rt.io, odir, max_object_bytes);

    var hdrs = try objectHeaders(a, meta);

    // Single-range support.
    if (req.headers.get("range")) |rv| {
        if (headers.parseRange(rv)) |r| {
            const total = data.len;
            var start: u64 = r.start orelse 0;
            var end: u64 = if (r.end) |e| e else total - 1;
            if (r.start == null and r.end != null) {
                // suffix: last N bytes
                const n = r.end.?;
                start = if (n >= total) 0 else total - n;
                end = total - 1;
            }
            if (start >= total) return errResp(req, .invalid_range);
            if (end >= total) end = total - 1;
            const slice = data[@intCast(start)..@intCast(end + 1)];
            const cr = try std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ start, end, total });
            hdrs = try appendHeader(a, hdrs, .{ .name = "content-range", .value = cr });
            return .{ .status = 206, .headers = hdrs, .body = slice, .content_type = meta.content_type };
        }
    }

    return .{ .headers = hdrs, .body = data, .content_type = meta.content_type };
}

pub fn headObject(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return .{ .status = 404 };
    const key = req.key orelse return .{ .status = 404 };
    const b = rt.registry.get(bucket) orelse return .{ .status = 404 };

    b.mutex.lockUncancelable(rt.io);
    defer b.mutex.unlock(rt.io);

    const meta = b.object_index.get(key) orelse return .{ .status = 404 };
    const a = req.arena.allocator();
    var hdrs = try objectHeaders(a, meta);
    const clen = try std.fmt.allocPrint(a, "{d}", .{meta.size});
    hdrs = try appendHeader(a, hdrs, .{ .name = "content-length", .value = clen });
    return .{ .headers = hdrs, .content_type = meta.content_type };
}

pub fn deleteObject(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    const key = req.key orelse return .{ .status = 204 };
    const b = rt.registry.get(bucket) orelse return errResp(req, .no_such_bucket);

    b.mutex.lockUncancelable(rt.io);
    defer b.mutex.unlock(rt.io);

    const a = req.arena.allocator();
    const odir = try object_dir.objectDir(a, b.dir, key);
    object_dir.remove(rt.io, odir) catch {};
    _ = b.object_index.remove(key);
    return .{ .status = 204 };
}

pub fn deleteObjects(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    const b = rt.registry.get(bucket) orelse return errResp(req, .no_such_bucket);
    const a = req.arena.allocator();

    const keys = try extractKeys(a, req.body);
    const quiet = std.mem.indexOf(u8, req.body, "<Quiet>true</Quiet>") != null;

    b.mutex.lockUncancelable(rt.io);
    defer b.mutex.unlock(rt.io);

    var x = xml.Writer.init(a);
    try x.declaration();
    try x.openNs("DeleteResult", xml.s3_ns);
    for (keys) |key| {
        const odir = try object_dir.objectDir(a, b.dir, key);
        object_dir.remove(rt.io, odir) catch {};
        _ = b.object_index.remove(key);
        if (!quiet) {
            try x.open("Deleted");
            try x.element("Key", key);
            try x.close("Deleted");
        }
    }
    try x.close("DeleteResult");
    return .{ .body = x.finish() };
}

pub fn copyObject(rt: *Runtime, req: *Request) !Response {
    const dst_bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    const dst_key = req.key orelse return errResp(req, .invalid_argument);
    const src = req.headers.get("x-amz-copy-source") orelse return errResp(req, .invalid_argument);
    const a = req.arena.allocator();

    const parsed = parseCopySource(src) orelse return errResp(req, .invalid_argument);
    const src_b = rt.registry.get(parsed.bucket) orelse return errResp(req, .no_such_bucket);
    const dst_b = rt.registry.get(dst_bucket) orelse return errResp(req, .no_such_bucket);

    // Read source under its lock.
    src_b.mutex.lockUncancelable(rt.io);
    const src_meta = src_b.object_index.get(parsed.key);
    var data: []u8 = &.{};
    var src_ct: []const u8 = "application/octet-stream";
    if (src_meta) |m| {
        const sdir = try object_dir.objectDir(a, src_b.dir, parsed.key);
        data = object_dir.readData(a, rt.io, sdir, max_object_bytes) catch &.{};
        src_ct = m.content_type;
    }
    src_b.mutex.unlock(rt.io);
    if (src_meta == null) return errResp(req, .no_such_key);

    var etag: [32]u8 = undefined;
    md5.hexLower(&etag, data);
    const now_ms = nowMillis(rt);

    dst_b.mutex.lockUncancelable(rt.io);
    defer dst_b.mutex.unlock(rt.io);

    const odir = try object_dir.ensureDir(a, rt.io, dst_b.dir, dst_key);
    try object_dir.writeData(a, rt.io, odir, data, rt.fsync);
    const ba = dst_b.arena.allocator();
    const meta: ObjectMeta = .{
        .key = try ba.dupe(u8, dst_key),
        .etag = etag,
        .size = data.len,
        .content_type = try ba.dupe(u8, src_ct),
        .last_modified_ms = now_ms,
    };
    try object_dir.writeMeta(a, rt.io, odir, meta, rt.fsync);
    try dst_b.object_index.put(meta);

    var x = xml.Writer.init(a);
    try x.declaration();
    try x.openNs("CopyObjectResult", xml.s3_ns);
    try x.element("LastModified", try isoTime(a, @divTrunc(now_ms, 1000)));
    try x.element("ETag", try quotedEtag(a, &etag));
    try x.close("CopyObjectResult");
    return .{ .body = x.finish() };
}

// ---- listing -------------------------------------------------------------

pub fn listObjects(rt: *Runtime, req: *Request, v2: bool) !Response {
    const bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    const b = rt.registry.get(bucket) orelse return errResp(req, .no_such_bucket);
    const a = req.arena.allocator();

    const prefix = req.query.get("prefix") orelse "";
    const delimiter = req.query.get("delimiter");
    const max_keys = blk: {
        const mv = req.query.get("max-keys") orelse break :blk default_max_keys;
        break :blk std.fmt.parseInt(usize, mv, 10) catch default_max_keys;
    };
    const marker = if (v2)
        (req.query.get("continuation-token") orelse req.query.get("start-after"))
    else
        req.query.get("marker");

    b.mutex.lockUncancelable(rt.io);
    defer b.mutex.unlock(rt.io);

    const all = b.object_index.rangeFrom(marker);

    var contents: std.ArrayList([]const u8) = .empty; // keys
    var common: std.ArrayList([]const u8) = .empty; // common prefixes
    var truncated = false;
    var next_token: ?[]const u8 = null;
    var emitted: usize = 0;

    for (all) |key| {
        if (!std.mem.startsWith(u8, key, prefix)) continue;
        if (emitted >= max_keys) {
            truncated = true;
            break;
        }
        if (delimiter) |d| {
            const rest = key[prefix.len..];
            if (std.mem.indexOf(u8, rest, d)) |di| {
                const cp = key[0 .. prefix.len + di + d.len];
                if (common.items.len == 0 or !std.mem.eql(u8, common.items[common.items.len - 1], cp)) {
                    try common.append(a, try a.dupe(u8, cp));
                    emitted += 1;
                    next_token = key;
                }
                continue;
            }
        }
        try contents.append(a, key);
        emitted += 1;
        next_token = key;
    }

    var x = xml.Writer.init(a);
    try x.declaration();
    try x.openNs("ListBucketResult", xml.s3_ns);
    try x.element("Name", bucket);
    try x.element("Prefix", prefix);
    if (delimiter) |d| try x.element("Delimiter", d);
    try x.elementInt("MaxKeys", @intCast(max_keys));
    if (v2) {
        try x.elementInt("KeyCount", @intCast(contents.items.len + common.items.len));
        if (req.query.get("continuation-token")) |ct| try x.element("ContinuationToken", ct);
        if (truncated) if (next_token) |nt| try x.element("NextContinuationToken", nt);
    } else {
        if (marker) |m| try x.element("Marker", m);
        if (truncated) if (next_token) |nt| try x.element("NextMarker", nt);
    }
    try x.elementBool("IsTruncated", truncated);

    for (contents.items) |key| {
        const meta = b.object_index.get(key) orelse continue;
        try x.open("Contents");
        try x.element("Key", key);
        try x.element("LastModified", try isoTime(a, @divTrunc(meta.last_modified_ms, 1000)));
        try x.element("ETag", try renderedEtag(a, meta));
        try x.elementInt("Size", @intCast(meta.size));
        try x.element("StorageClass", meta.storage_class);
        try x.close("Contents");
    }
    for (common.items) |cp| {
        try x.open("CommonPrefixes");
        try x.element("Prefix", cp);
        try x.close("CommonPrefixes");
    }
    try x.close("ListBucketResult");
    return .{ .body = x.finish() };
}

// ---- multipart -----------------------------------------------------------

pub fn createMultipart(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    const key = req.key orelse return errResp(req, .invalid_argument);
    const b = rt.registry.get(bucket) orelse return errResp(req, .no_such_bucket);
    const a = req.arena.allocator();

    var upload_id: [36]u8 = undefined;
    idgen.uuidV4(rt.rng, &upload_id);

    b.mutex.lockUncancelable(rt.io);
    defer b.mutex.unlock(rt.io);

    const u = try b.upload_index.create(upload_id, key, contentTypeOf(req), nowMillis(rt));
    const pairs = try headers.collectUserMeta(a, req.headers.items);
    for (pairs) |p| try u.putUserMeta(p.name, p.value);

    const ubase = try upload_dir.ensureDir(a, rt.io, b.dir, &upload_id);
    try upload_dir.writeMeta(a, rt.io, ubase, u, rt.fsync);

    var x = xml.Writer.init(a);
    try x.declaration();
    try x.openNs("InitiateMultipartUploadResult", xml.s3_ns);
    try x.element("Bucket", bucket);
    try x.element("Key", key);
    try x.element("UploadId", &upload_id);
    try x.close("InitiateMultipartUploadResult");
    return .{ .body = x.finish() };
}

pub fn uploadPart(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    const b = rt.registry.get(bucket) orelse return errResp(req, .no_such_bucket);
    const a = req.arena.allocator();
    const upload_id = req.query.get("uploadId") orelse return errResp(req, .no_such_upload);
    const part_str = req.query.get("partNumber") orelse return errResp(req, .invalid_argument);
    const n = std.fmt.parseInt(u16, part_str, 10) catch return errResp(req, .invalid_argument);
    if (n < 1 or n > 10000) return errResp(req, .invalid_argument);

    b.mutex.lockUncancelable(rt.io);
    defer b.mutex.unlock(rt.io);

    const u = b.upload_index.get(upload_id) orelse return errResp(req, .no_such_upload);

    var etag: [32]u8 = undefined;
    md5.hexLower(&etag, req.body);

    const ubase = try upload_dir.uploadDir(a, b.dir, upload_id);
    try upload_dir.writePart(a, rt.io, ubase, n, req.body, rt.fsync);
    try u.putPart(.{ .n = n, .etag = etag, .size = req.body.len });
    try upload_dir.writeMeta(a, rt.io, ubase, u, rt.fsync);

    return .{ .headers = try dupHeaders(a, &.{.{ .name = "etag", .value = try quotedEtag(a, &etag) }}) };
}

pub fn completeMultipart(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    const key = req.key orelse return errResp(req, .invalid_argument);
    const b = rt.registry.get(bucket) orelse return errResp(req, .no_such_bucket);
    const a = req.arena.allocator();
    const upload_id = req.query.get("uploadId") orelse return errResp(req, .no_such_upload);

    b.mutex.lockUncancelable(rt.io);
    defer b.mutex.unlock(rt.io);

    const u = b.upload_index.get(upload_id) orelse return errResp(req, .no_such_upload);
    if (u.parts.items.len == 0) return errResp(req, .invalid_part);

    const ubase = try upload_dir.uploadDir(a, b.dir, upload_id);
    const odir = try object_dir.ensureDir(a, rt.io, b.dir, key);
    const dest = try object_dir.dataPath(a, odir);
    const total = try upload_dir.assemble(a, rt.io, ubase, dest, u.parts.items, rt.fsync);

    const etag_str = try multipart.computeMultipartEtag(a, u.parts.items);
    // Stored etag is the base md5 hex (first 32 chars); part count drives "-N".
    var etag: [32]u8 = undefined;
    @memcpy(&etag, etag_str[0..32]);

    const ba = b.arena.allocator();
    var um: object_store.UserMeta = .empty;
    var umit = u.user_meta.iterator();
    while (umit.next()) |e| try um.put(ba, try ba.dupe(u8, e.key_ptr.*), try ba.dupe(u8, e.value_ptr.*));
    const meta: ObjectMeta = .{
        .key = try ba.dupe(u8, key),
        .etag = etag,
        .multipart_part_count = @intCast(u.parts.items.len),
        .size = total,
        .content_type = try ba.dupe(u8, u.content_type),
        .user_meta = um,
        .last_modified_ms = nowMillis(rt),
    };
    try object_dir.writeMeta(a, rt.io, odir, meta, rt.fsync);
    try b.object_index.put(meta);

    upload_dir.remove(rt.io, ubase) catch {};
    _ = b.upload_index.remove(upload_id);

    const loc = try std.fmt.allocPrint(a, "/{s}/{s}", .{ bucket, key });
    var x = xml.Writer.init(a);
    try x.declaration();
    try x.openNs("CompleteMultipartUploadResult", xml.s3_ns);
    try x.element("Location", loc);
    try x.element("Bucket", bucket);
    try x.element("Key", key);
    try x.element("ETag", try quotedEtag(a, etag_str));
    try x.close("CompleteMultipartUploadResult");
    return .{ .body = x.finish() };
}

pub fn abortMultipart(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    const b = rt.registry.get(bucket) orelse return errResp(req, .no_such_bucket);
    const a = req.arena.allocator();
    const upload_id = req.query.get("uploadId") orelse return errResp(req, .no_such_upload);

    b.mutex.lockUncancelable(rt.io);
    defer b.mutex.unlock(rt.io);

    if (!b.upload_index.remove(upload_id)) return errResp(req, .no_such_upload);
    const ubase = try upload_dir.uploadDir(a, b.dir, upload_id);
    upload_dir.remove(rt.io, ubase) catch {};
    return .{ .status = 204 };
}

pub fn listParts(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    const key = req.key orelse return errResp(req, .invalid_argument);
    const b = rt.registry.get(bucket) orelse return errResp(req, .no_such_bucket);
    const a = req.arena.allocator();
    const upload_id = req.query.get("uploadId") orelse return errResp(req, .no_such_upload);

    b.mutex.lockUncancelable(rt.io);
    defer b.mutex.unlock(rt.io);

    const u = b.upload_index.get(upload_id) orelse return errResp(req, .no_such_upload);

    var x = xml.Writer.init(a);
    try x.declaration();
    try x.openNs("ListPartsResult", xml.s3_ns);
    try x.element("Bucket", bucket);
    try x.element("Key", key);
    try x.element("UploadId", upload_id);
    try x.elementBool("IsTruncated", false);
    for (u.parts.items) |p| {
        try x.open("Part");
        try x.elementInt("PartNumber", p.n);
        try x.element("ETag", try quotedEtag(a, &p.etag));
        try x.elementInt("Size", @intCast(p.size));
        try x.close("Part");
    }
    try x.close("ListPartsResult");
    return .{ .body = x.finish() };
}

pub fn listMultipartUploads(rt: *Runtime, req: *Request) !Response {
    const bucket = req.bucket orelse return errResp(req, .no_such_bucket);
    const b = rt.registry.get(bucket) orelse return errResp(req, .no_such_bucket);
    const a = req.arena.allocator();

    b.mutex.lockUncancelable(rt.io);
    defer b.mutex.unlock(rt.io);

    const uploads = try b.upload_index.list(a);

    var x = xml.Writer.init(a);
    try x.declaration();
    try x.openNs("ListMultipartUploadsResult", xml.s3_ns);
    try x.element("Bucket", bucket);
    try x.elementBool("IsTruncated", false);
    for (uploads) |u| {
        try x.open("Upload");
        try x.element("Key", u.key);
        try x.element("UploadId", u.idSlice());
        try x.element("Initiated", try isoTime(a, @divTrunc(u.initiated_at_ms, 1000)));
        try x.close("Upload");
    }
    try x.close("ListMultipartUploadsResult");
    return .{ .body = x.finish() };
}

// ---- small utilities -----------------------------------------------------

fn objectHeaders(arena: std.mem.Allocator, meta: *const ObjectMeta) ![]std.http.Header {
    var list: std.ArrayList(std.http.Header) = .empty;
    try list.append(arena, .{ .name = "etag", .value = try renderedEtag(arena, meta) });
    try list.append(arena, .{ .name = "last-modified", .value = try isoTime(arena, @divTrunc(meta.last_modified_ms, 1000)) });
    try list.append(arena, .{ .name = "accept-ranges", .value = "bytes" });
    var it = meta.user_meta.iterator();
    while (it.next()) |e| {
        const name = try std.fmt.allocPrint(arena, "x-amz-meta-{s}", .{e.key_ptr.*});
        try list.append(arena, .{ .name = name, .value = e.value_ptr.* });
    }
    return list.items;
}

// Single-shot objects render the bare md5 hex; multipart objects append "-N".
fn renderedEtag(arena: std.mem.Allocator, meta: *const ObjectMeta) ![]const u8 {
    if (meta.multipart_part_count > 0) {
        return std.fmt.allocPrint(arena, "\"{s}-{d}\"", .{ meta.etag, meta.multipart_part_count });
    }
    return std.fmt.allocPrint(arena, "\"{s}\"", .{meta.etag});
}

fn appendHeader(arena: std.mem.Allocator, hdrs: []std.http.Header, h: std.http.Header) ![]std.http.Header {
    var list: std.ArrayList(std.http.Header) = .empty;
    try list.appendSlice(arena, hdrs);
    try list.append(arena, h);
    return list.items;
}

fn dupHeaders(arena: std.mem.Allocator, hdrs: []const std.http.Header) ![]const std.http.Header {
    const out = try arena.alloc(std.http.Header, hdrs.len);
    @memcpy(out, hdrs);
    return out;
}

const CopySource = struct { bucket: []const u8, key: []const u8 };

fn parseCopySource(src: []const u8) ?CopySource {
    var s = src;
    if (s.len > 0 and s[0] == '/') s = s[1..];
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return null;
    const bucket = s[0..slash];
    var key = s[slash + 1 ..];
    if (std.mem.indexOfScalar(u8, key, '?')) |q| key = key[0..q];
    if (bucket.len == 0 or key.len == 0) return null;
    return .{ .bucket = bucket, .key = key };
}

// Extract <Key>...</Key> values from a DeleteObjects request body.
fn extractKeys(arena: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var rest = body;
    while (std.mem.indexOf(u8, rest, "<Key>")) |start| {
        const after = rest[start + 5 ..];
        const end = std.mem.indexOf(u8, after, "</Key>") orelse break;
        try out.append(arena, try unescapeXml(arena, after[0..end]));
        rest = after[end + 6 ..];
    }
    return out.items;
}

fn unescapeXml(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (std.mem.startsWith(u8, s[i..], "&amp;")) {
                try out.append(arena, '&');
                i += 5;
            } else if (std.mem.startsWith(u8, s[i..], "&lt;")) {
                try out.append(arena, '<');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&gt;")) {
                try out.append(arena, '>');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&quot;")) {
                try out.append(arena, '"');
                i += 6;
            } else if (std.mem.startsWith(u8, s[i..], "&apos;")) {
                try out.append(arena, '\'');
                i += 6;
            } else {
                try out.append(arena, s[i]);
                i += 1;
            }
        } else {
            try out.append(arena, s[i]);
            i += 1;
        }
    }
    return out.items;
}

const testing = std.testing;

test "parseCopySource path and leading slash" {
    const a = parseCopySource("/src-bucket/path/to/key").?;
    try testing.expectEqualStrings("src-bucket", a.bucket);
    try testing.expectEqualStrings("path/to/key", a.key);
    const b = parseCopySource("buck/key?versionId=1").?;
    try testing.expectEqualStrings("buck", b.bucket);
    try testing.expectEqualStrings("key", b.key);
    try testing.expect(parseCopySource("nokey") == null);
}

test "extractKeys parses delete body and unescapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "<Delete><Object><Key>a/b</Key></Object><Object><Key>x&amp;y</Key></Object></Delete>";
    const keys = try extractKeys(arena.allocator(), body);
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expectEqualStrings("a/b", keys[0]);
    try testing.expectEqualStrings("x&y", keys[1]);
}

test "isoTime formats epoch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try isoTime(arena.allocator(), 1717689600);
    try testing.expectEqualStrings("2024-06-06T16:00:00.000Z", s);
}
