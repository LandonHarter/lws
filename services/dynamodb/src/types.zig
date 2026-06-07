const std = @import("std");

pub const AttributeValue = union(enum) {
    S: []const u8,
    N: []const u8,
    B: []const u8,
    BOOL: bool,
    NULL,
    L: []AttributeValue,
    M: std.StringArrayHashMapUnmanaged(AttributeValue),
    SS: [][]const u8,
    NS: [][]const u8,
    BS: [][]const u8,
};

pub const Item = struct {
    attrs: std.StringArrayHashMapUnmanaged(AttributeValue) = .empty,
};

pub const ScalarKind = enum { S, N, B };

pub const KeyDef = struct {
    name: []const u8,
    kind: ScalarKind,
};

pub const KeySchema = struct {
    partition: KeyDef,
    sort: ?KeyDef = null,
};

pub const IndexKind = enum { GSI, LSI };

pub const IndexStatus = enum { CREATING, ACTIVE, UPDATING, DELETING };

pub const IndexProjection = union(enum) {
    KEYS_ONLY,
    INCLUDE: [][]const u8,
    ALL,
};

pub const SecondaryIndex = struct {
    name: []const u8,
    kind: IndexKind,
    schema: KeySchema,
    projection: IndexProjection,
    status: IndexStatus = .ACTIVE,
};

pub const TableStatus = enum { CREATING, ACTIVE, UPDATING, DELETING };

pub const BillingMode = enum { PROVISIONED, PAY_PER_REQUEST };

pub const Tag = struct {
    key: []const u8,
    value: []const u8,
};

pub const TableSchema = struct {
    name: []const u8,
    key_schema: KeySchema,
    attribute_defs: []KeyDef = &.{},
    indexes: []SecondaryIndex = &.{},
    billing_mode: BillingMode = .PAY_PER_REQUEST,
    ttl_attribute: ?[]const u8 = null,
    ttl_enabled: bool = false,
    tags: []Tag = &.{},
    table_id: []const u8 = "",
    created_at_ms: i64 = 0,
    status: TableStatus = .CREATING,
    item_count: u64 = 0,
    bytes: u64 = 0,
};

pub const NumberError = error{InvalidNumber};

// Canonical decimal text for a DynamoDB number. Trims sign/leading/trailing
// zeros and expands scientific notation so conditional expressions can compare
// numbers as bytes. `+0001.500` -> `1.5`, `1.5e2` -> `150`, `-0` -> `0`.
pub fn canonicalizeNumber(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var i: usize = 0;
    var negative = false;
    if (i < raw.len and (raw[i] == '+' or raw[i] == '-')) {
        negative = raw[i] == '-';
        i += 1;
    }

    var digits: std.ArrayListUnmanaged(u8) = .empty;
    defer digits.deinit(a);
    var frac_digits: i64 = 0;
    var seen_dot = false;
    var seen_digit = false;
    var has_exp = false;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '.') {
            if (seen_dot) return NumberError.InvalidNumber;
            seen_dot = true;
        } else if (c >= '0' and c <= '9') {
            seen_digit = true;
            try digits.append(a, c);
            if (seen_dot) frac_digits += 1;
        } else if (c == 'e' or c == 'E') {
            i += 1;
            has_exp = true;
            break;
        } else {
            return NumberError.InvalidNumber;
        }
    }
    if (!seen_digit) return NumberError.InvalidNumber;

    var exp: i64 = 0;
    if (has_exp) {
        var exp_neg = false;
        if (i < raw.len and (raw[i] == '+' or raw[i] == '-')) {
            exp_neg = raw[i] == '-';
            i += 1;
        }
        var seen_exp_digit = false;
        while (i < raw.len) : (i += 1) {
            const c = raw[i];
            if (c < '0' or c > '9') return NumberError.InvalidNumber;
            seen_exp_digit = true;
            exp = exp * 10 + @as(i64, c - '0');
        }
        if (!seen_exp_digit) return NumberError.InvalidNumber;
        if (exp_neg) exp = -exp;
    }

    // value == digits * 10^net
    const net = exp - frac_digits;

    // Strip leading zeros from the raw digit string (keep significance only).
    var ds = digits.items;
    var lead: usize = 0;
    while (lead < ds.len and ds[lead] == '0') lead += 1;
    ds = ds[lead..];
    if (ds.len == 0) return a.dupe(u8, "0"); // all zeros

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);

    if (net >= 0) {
        try out.appendSlice(a, ds);
        var z: i64 = 0;
        while (z < net) : (z += 1) try out.append(a, '0');
    } else {
        const k: usize = @intCast(-net);
        if (k >= ds.len) {
            // 0.<zeros><ds>, then trim trailing zeros of fraction
            var frac: std.ArrayListUnmanaged(u8) = .empty;
            defer frac.deinit(a);
            var z: usize = 0;
            while (z < k - ds.len) : (z += 1) try frac.append(a, '0');
            try frac.appendSlice(a, ds);
            var end: usize = frac.items.len;
            while (end > 0 and frac.items[end - 1] == '0') end -= 1;
            if (end == 0) {
                try out.append(a, '0');
            } else {
                try out.append(a, '0');
                try out.append(a, '.');
                try out.appendSlice(a, frac.items[0..end]);
            }
        } else {
            const split = ds.len - k;
            const int_part = ds[0..split];
            var frac_end: usize = ds.len;
            while (frac_end > split and ds[frac_end - 1] == '0') frac_end -= 1;
            try out.appendSlice(a, int_part);
            if (frac_end > split) {
                try out.append(a, '.');
                try out.appendSlice(a, ds[split..frac_end]);
            }
        }
    }

    if (negative and !(out.items.len == 1 and out.items[0] == '0')) {
        try out.insert(a, 0, '-');
    }
    return out.toOwnedSlice(a);
}

// Ordering of two canonical (or raw) decimal numbers by value.
pub fn compareNumber(a_raw: []const u8, b_raw: []const u8) std.math.Order {
    var sa = std.heap.stackFallback(64, std.heap.page_allocator);
    const alloc = sa.get();
    const ca = canonicalizeNumber(alloc, a_raw) catch return .eq;
    defer alloc.free(ca);
    const cb = canonicalizeNumber(alloc, b_raw) catch return .eq;
    defer alloc.free(cb);
    return compareCanonical(ca, cb);
}

fn compareCanonical(a: []const u8, b: []const u8) std.math.Order {
    const a_neg = a.len > 0 and a[0] == '-';
    const b_neg = b.len > 0 and b[0] == '-';
    if (a_neg and !b_neg) return .lt;
    if (!a_neg and b_neg) return .gt;
    const am = if (a_neg) a[1..] else a;
    const bm = if (b_neg) b[1..] else b;
    const mag = compareMagnitude(am, bm);
    if (!a_neg) return mag;
    return switch (mag) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    };
}

fn compareMagnitude(a: []const u8, b: []const u8) std.math.Order {
    const a_dot = std.mem.indexOfScalar(u8, a, '.') orelse a.len;
    const b_dot = std.mem.indexOfScalar(u8, b, '.') orelse b.len;
    const a_int = a[0..a_dot];
    const b_int = b[0..b_dot];
    if (a_int.len != b_int.len) return std.math.order(a_int.len, b_int.len);
    if (std.mem.order(u8, a_int, b_int) != .eq) return std.mem.order(u8, a_int, b_int);
    const a_frac = if (a_dot < a.len) a[a_dot + 1 ..] else "";
    const b_frac = if (b_dot < b.len) b[b_dot + 1 ..] else "";
    const n = @max(a_frac.len, b_frac.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ad: u8 = if (i < a_frac.len) a_frac[i] else '0';
        const bd: u8 = if (i < b_frac.len) b_frac[i] else '0';
        if (ad != bd) return std.math.order(ad, bd);
    }
    return .eq;
}

// Dedup + sort a string set bytewise. Returns a fresh slice owned by `a`.
pub fn canonicalizeStringSet(a: std.mem.Allocator, set: []const []const u8) ![][]const u8 {
    return dedupSort(a, set, lessThanBytes);
}

// Dedup + sort a binary set bytewise.
pub fn canonicalizeBinarySet(a: std.mem.Allocator, set: []const []const u8) ![][]const u8 {
    return dedupSort(a, set, lessThanBytes);
}

// Canonicalize each element, then dedup + sort numerically.
pub fn canonicalizeNumberSet(a: std.mem.Allocator, set: []const []const u8) ![][]const u8 {
    const canon = try a.alloc([]const u8, set.len);
    for (set, 0..) |s, i| canon[i] = try canonicalizeNumber(a, s);
    return dedupSort(a, canon, lessThanNumber);
}

fn lessThanBytes(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn lessThanNumber(_: void, x: []const u8, y: []const u8) bool {
    return compareCanonical(x, y) == .lt;
}

fn dedupSort(
    a: std.mem.Allocator,
    set: []const []const u8,
    comptime lessThan: fn (void, []const u8, []const u8) bool,
) ![][]const u8 {
    var list = try a.alloc([]const u8, set.len);
    for (set, 0..) |s, i| list[i] = s;
    std.mem.sort([]const u8, list, {}, lessThan);
    var n: usize = 0;
    for (list, 0..) |s, i| {
        if (i > 0 and std.mem.eql(u8, list[i - 1], s)) continue;
        list[n] = s;
        n += 1;
    }
    if (n != list.len) list = try a.realloc(list, n);
    return list;
}

// Deep value equality. Tags must match; numbers compared as canonical bytes.
pub fn attrEq(a: AttributeValue, b: AttributeValue) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .S => |x| std.mem.eql(u8, x, b.S),
        .N => |x| compareNumber(x, b.N) == .eq,
        .B => |x| std.mem.eql(u8, x, b.B),
        .BOOL => |x| x == b.BOOL,
        .NULL => true,
        .L => |x| blk: {
            if (x.len != b.L.len) break :blk false;
            for (x, b.L) |xi, yi| if (!attrEq(xi, yi)) break :blk false;
            break :blk true;
        },
        .M => |x| blk: {
            if (x.count() != b.M.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = b.M.get(e.key_ptr.*) orelse break :blk false;
                if (!attrEq(e.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
        .SS, .BS => |x| sliceSetEq(x, switch (b) {
            .SS => b.SS,
            .BS => b.BS,
            else => unreachable,
        }),
        .NS => |x| blk: {
            if (x.len != b.NS.len) break :blk false;
            for (x, b.NS) |xi, yi| if (compareNumber(xi, yi) != .eq) break :blk false;
            break :blk true;
        },
    };
}

fn sliceSetEq(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |xi, yi| if (!std.mem.eql(u8, xi, yi)) return false;
    return true;
}

const testing = std.testing;

test "canonicalizeNumber trims and expands" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "+0001.500", .want = "1.5" },
        .{ .in = "1.5e2", .want = "150" },
        .{ .in = "+1.0e2", .want = "100" },
        .{ .in = "0", .want = "0" },
        .{ .in = "-0", .want = "0" },
        .{ .in = "007", .want = "7" },
        .{ .in = "-12.340", .want = "-12.34" },
        .{ .in = "1.5e-3", .want = "0.0015" },
        .{ .in = "100", .want = "100" },
        .{ .in = "0.0", .want = "0" },
    };
    for (cases) |c| {
        const got = try canonicalizeNumber(testing.allocator, c.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "canonicalizeNumber rejects junk" {
    try testing.expectError(NumberError.InvalidNumber, canonicalizeNumber(testing.allocator, "abc"));
    try testing.expectError(NumberError.InvalidNumber, canonicalizeNumber(testing.allocator, "1.2.3"));
    try testing.expectError(NumberError.InvalidNumber, canonicalizeNumber(testing.allocator, "1e"));
}

test "compareNumber orders by value" {
    try testing.expectEqual(std.math.Order.lt, compareNumber("9", "10"));
    try testing.expectEqual(std.math.Order.gt, compareNumber("10", "9"));
    try testing.expectEqual(std.math.Order.eq, compareNumber("1.50", "1.5"));
    try testing.expectEqual(std.math.Order.lt, compareNumber("-5", "1"));
    try testing.expectEqual(std.math.Order.lt, compareNumber("-10", "-9"));
    try testing.expectEqual(std.math.Order.lt, compareNumber("1.2", "1.3"));
    try testing.expectEqual(std.math.Order.gt, compareNumber("1.25", "1.2"));
}

test "string set dedup + sort" {
    const in = [_][]const u8{ "c", "a", "b", "a" };
    const out = try canonicalizeStringSet(testing.allocator, &in);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("a", out[0]);
    try testing.expectEqualStrings("b", out[1]);
    try testing.expectEqualStrings("c", out[2]);
}

test "number set canonicalizes, dedups, sorts numerically" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const in = [_][]const u8{ "10", "9", "1.50", "1.5" };
    const out = try canonicalizeNumberSet(arena.allocator(), &in);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("1.5", out[0]);
    try testing.expectEqualStrings("9", out[1]);
    try testing.expectEqualStrings("10", out[2]);
}

test "attrEq across variants" {
    try testing.expect(attrEq(.{ .S = "x" }, .{ .S = "x" }));
    try testing.expect(!attrEq(.{ .S = "x" }, .{ .S = "y" }));
    try testing.expect(attrEq(.{ .N = "1.50" }, .{ .N = "1.5" }));
    try testing.expect(attrEq(.{ .BOOL = true }, .{ .BOOL = true }));
    try testing.expect(!attrEq(.{ .BOOL = true }, .{ .BOOL = false }));
    try testing.expect(attrEq(.NULL, .NULL));
    try testing.expect(!attrEq(.{ .S = "x" }, .{ .N = "x" }));
    var l1 = [_]AttributeValue{ .{ .S = "a" }, .{ .N = "1" } };
    var l2 = [_]AttributeValue{ .{ .S = "a" }, .{ .N = "1.0" } };
    try testing.expect(attrEq(.{ .L = &l1 }, .{ .L = &l2 }));
    var ss1 = [_][]const u8{ "a", "b" };
    var ss2 = [_][]const u8{ "a", "b" };
    try testing.expect(attrEq(.{ .SS = &ss1 }, .{ .SS = &ss2 }));
}
