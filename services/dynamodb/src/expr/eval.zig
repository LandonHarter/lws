const std = @import("std");
const types = @import("../types.zig");
const item_store = @import("../store/item_store.zig");
const parser = @import("parser.zig");

const AttributeValue = types.AttributeValue;
const Item = types.Item;
const Path = parser.Path;
const Operand = parser.Operand;
const BoolExpr = parser.BoolExpr;

pub const EvalError = error{ Validation, OutOfMemory };

// Resolved substitution maps. `names` is keyed by the full `#ref` token, `values`
// by the full `:ref` token — matching the request's ExpressionAttribute* maps.
pub const Subst = struct {
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    values: std.StringHashMapUnmanaged(AttributeValue) = .empty,

    // `#ref` -> real name (error if undefined); a bare token is itself.
    fn resolveName(self: *const Subst, tok: []const u8) EvalError![]const u8 {
        if (tok.len > 0 and tok[0] == '#') return self.names.get(tok) orelse error.Validation;
        return tok;
    }

    fn resolveValue(self: *const Subst, tok: []const u8) EvalError!AttributeValue {
        return self.values.get(tok) orelse error.Validation;
    }
};

// ---- path resolution ----

fn navStep(cur: AttributeValue, step: parser.PathStep, subst: *const Subst) EvalError!?AttributeValue {
    switch (step) {
        .attr => |name_tok| {
            if (cur != .M) return null;
            const name = try subst.resolveName(name_tok);
            return cur.M.get(name);
        },
        .index => |idx| {
            if (cur != .L) return null;
            if (idx >= cur.L.len) return null;
            return cur.L[idx];
        },
    }
}

fn resolvePath(item: ?Item, path: Path, subst: *const Subst) EvalError!?AttributeValue {
    const it = item orelse return null;
    const root = try subst.resolveName(path.root);
    var cur = it.attrs.get(root) orelse return null;
    for (path.steps) |step| {
        cur = (try navStep(cur, step, subst)) orelse return null;
    }
    return cur;
}

fn operandValue(a: std.mem.Allocator, op: Operand, item: ?Item, subst: *const Subst) EvalError!?AttributeValue {
    return switch (op) {
        .path => |p| resolvePath(item, p, subst),
        .value => |tok| try subst.resolveValue(tok),
        .size => |p| blk: {
            const v = (try resolvePath(item, p, subst)) orelse break :blk null;
            const n = sizeOf(v) orelse break :blk null;
            const s = try std.fmt.allocPrint(a, "{d}", .{n});
            break :blk AttributeValue{ .N = s };
        },
    };
}

fn sizeOf(v: AttributeValue) ?u64 {
    return switch (v) {
        .S, .B => |s| s.len,
        .L => |l| l.len,
        .M => |m| m.count(),
        .SS, .NS, .BS => |set| set.len,
        else => null,
    };
}

// ---- comparisons ----

// Ordered comparison for <,<=,>,>= — only when both are the same comparable type.
fn compareValues(x: AttributeValue, y: AttributeValue) ?std.math.Order {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return null;
    return switch (x) {
        .N => types.compareNumber(x.N, y.N),
        .S => std.mem.order(u8, x.S, y.S),
        .B => std.mem.order(u8, x.B, y.B),
        else => null,
    };
}

pub fn evalBool(a: std.mem.Allocator, node: *const BoolExpr, item: ?Item, subst: *const Subst) EvalError!bool {
    return switch (node.*) {
        .and_ => |x| {
            const l = try evalBool(a, x.lhs, item, subst);
            const r = try evalBool(a, x.rhs, item, subst);
            return l and r;
        },
        .or_ => |x| {
            const l = try evalBool(a, x.lhs, item, subst);
            const r = try evalBool(a, x.rhs, item, subst);
            return l or r;
        },
        .not_ => |x| !(try evalBool(a, x, item, subst)),
        .compare => |c| blk: {
            const lhs = (try operandValue(a, c.lhs, item, subst)) orelse break :blk false;
            const rhs = (try operandValue(a, c.rhs, item, subst)) orelse break :blk false;
            break :blk switch (c.op) {
                .eq => types.attrEq(lhs, rhs),
                .ne => !types.attrEq(lhs, rhs),
                .lt => (compareValues(lhs, rhs) orelse break :blk false) == .lt,
                .le => (compareValues(lhs, rhs) orelse break :blk false) != .gt,
                .gt => (compareValues(lhs, rhs) orelse break :blk false) == .gt,
                .ge => (compareValues(lhs, rhs) orelse break :blk false) != .lt,
            };
        },
        .between => |b| blk: {
            const v = (try operandValue(a, b.val, item, subst)) orelse break :blk false;
            const lo = (try operandValue(a, b.lo, item, subst)) orelse break :blk false;
            const hi = (try operandValue(a, b.hi, item, subst)) orelse break :blk false;
            const ord_lo = compareValues(v, lo) orelse break :blk false;
            const ord_hi = compareValues(v, hi) orelse break :blk false;
            break :blk ord_lo != .lt and ord_hi != .gt;
        },
        .in_set => |s| blk: {
            const v = (try operandValue(a, s.val, item, subst)) orelse break :blk false;
            for (s.set) |elem| {
                const ev = (try operandValue(a, elem, item, subst)) orelse continue;
                if (types.attrEq(v, ev)) break :blk true;
            }
            break :blk false;
        },
        .attribute_exists => |p| (try resolvePath(item, p, subst)) != null,
        .attribute_not_exists => |p| (try resolvePath(item, p, subst)) == null,
        .attribute_type => |at| blk: {
            const v = (try resolvePath(item, at.path, subst)) orelse break :blk false;
            const tv = try subst.resolveValue(at.type_ref);
            if (tv != .S) break :blk false;
            break :blk std.mem.eql(u8, @tagName(std.meta.activeTag(v)), tv.S);
        },
        .begins_with => |bw| blk: {
            const v = (try resolvePath(item, bw.path, subst)) orelse break :blk false;
            const pre = (try operandValue(a, bw.prefix, item, subst)) orelse break :blk false;
            const hay: []const u8 = switch (v) {
                .S => v.S,
                .B => v.B,
                else => break :blk false,
            };
            const needle: []const u8 = switch (pre) {
                .S => pre.S,
                .B => pre.B,
                else => break :blk false,
            };
            break :blk std.mem.startsWith(u8, hay, needle);
        },
        .contains => |ct| blk: {
            const v = (try resolvePath(item, ct.path, subst)) orelse break :blk false;
            const target = (try operandValue(a, ct.operand, item, subst)) orelse break :blk false;
            break :blk containsValue(v, target);
        },
    };
}

fn containsValue(container: AttributeValue, target: AttributeValue) bool {
    return switch (container) {
        .S => target == .S and std.mem.indexOf(u8, container.S, target.S) != null,
        .L => |l| blk: {
            for (l) |e| if (types.attrEq(e, target)) break :blk true;
            break :blk false;
        },
        .SS => |set| target == .S and bytesInSet(set, target.S),
        .BS => |set| target == .B and bytesInSet(set, target.B),
        .NS => |set| blk: {
            if (target != .N) break :blk false;
            for (set) |e| if (types.compareNumber(e, target.N) == .eq) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn bytesInSet(set: []const []const u8, needle: []const u8) bool {
    for (set) |e| if (std.mem.eql(u8, e, needle)) return true;
    return false;
}

// ---- update application ----

pub const ApplyResult = struct {
    after: Item,
    changed: [][]const u8, // top-level attribute names touched
};

pub fn applyUpdate(a: std.mem.Allocator, prog: parser.UpdateProgram, current: ?Item, subst: *const Subst) EvalError!ApplyResult {
    var next: Item = if (current) |c| try item_store.cloneItem(a, c) else .{};
    var changed: std.ArrayListUnmanaged([]const u8) = .empty;

    for (prog.clauses) |clause| {
        switch (clause) {
            .set => |s| {
                const v = try evalSetValue(a, s.value, next, subst);
                try setAtPath(a, &next, s.path, v, subst);
                try noteChanged(a, &changed, try subst.resolveName(s.path.root));
            },
            .remove => |p| {
                try removeAtPath(&next, p, subst);
                try noteChanged(a, &changed, try subst.resolveName(p.root));
            },
            .add => |ad| {
                const operand = try subst.resolveValue(ad.value);
                try applyAdd(a, &next, ad.path, operand, subst);
                try noteChanged(a, &changed, try subst.resolveName(ad.path.root));
            },
            .delete => |dl| {
                const operand = try subst.resolveValue(dl.value);
                try applyDelete(a, &next, dl.path, operand, subst);
                try noteChanged(a, &changed, try subst.resolveName(dl.path.root));
            },
        }
    }
    return .{ .after = next, .changed = try changed.toOwnedSlice(a) };
}

fn noteChanged(a: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), name: []const u8) EvalError!void {
    for (list.items) |n| if (std.mem.eql(u8, n, name)) return;
    try list.append(a, name);
}

fn evalSetValue(a: std.mem.Allocator, sv: parser.SetValue, item: Item, subst: *const Subst) EvalError!AttributeValue {
    return switch (sv) {
        .operand => |op| (try updOperandValue(a, op, item, subst)) orelse error.Validation,
        .plus => |pm| try arithmetic(a, pm.lhs, pm.rhs, item, subst, true),
        .minus => |pm| try arithmetic(a, pm.lhs, pm.rhs, item, subst, false),
    };
}

fn arithmetic(a: std.mem.Allocator, lhs: parser.UpdOperand, rhs: parser.UpdOperand, item: Item, subst: *const Subst, add: bool) EvalError!AttributeValue {
    const l = (try updOperandValue(a, lhs, item, subst)) orelse return error.Validation;
    const r = (try updOperandValue(a, rhs, item, subst)) orelse return error.Validation;
    if (l != .N or r != .N) return error.Validation;
    const out = if (add) try addNumbers(a, l.N, r.N) else try subNumbers(a, l.N, r.N);
    return .{ .N = out };
}

fn updOperandValue(a: std.mem.Allocator, op: parser.UpdOperand, item: Item, subst: *const Subst) EvalError!?AttributeValue {
    return switch (op) {
        .path => |p| try resolvePath(item, p, subst),
        .value => |tok| try subst.resolveValue(tok),
        .if_not_exists => |ine| blk: {
            if (try resolvePath(item, ine.path, subst)) |existing| break :blk existing;
            break :blk try updOperandValue(a, ine.default.*, item, subst);
        },
        .list_append => |la| blk: {
            const l = (try updOperandValue(a, la.lhs.*, item, subst)) orelse break :blk error.Validation;
            const r = (try updOperandValue(a, la.rhs.*, item, subst)) orelse break :blk error.Validation;
            if (l != .L or r != .L) break :blk error.Validation;
            const merged = try a.alloc(AttributeValue, l.L.len + r.L.len);
            @memcpy(merged[0..l.L.len], l.L);
            @memcpy(merged[l.L.len..], r.L);
            break :blk AttributeValue{ .L = merged };
        },
    };
}

// Descend to the slot named by `path`, creating intermediate maps, and write v.
fn setAtPath(a: std.mem.Allocator, item: *Item, path: Path, v: AttributeValue, subst: *const Subst) EvalError!void {
    const root = try subst.resolveName(path.root);
    if (path.steps.len == 0) {
        try item.attrs.put(a, try a.dupe(u8, root), v);
        return;
    }
    if (!item.attrs.contains(root)) {
        try item.attrs.put(a, try a.dupe(u8, root), .{ .M = .empty });
    }
    var cur = item.attrs.getPtr(root).?;
    for (path.steps[0 .. path.steps.len - 1]) |step| {
        cur = try descend(a, cur, step, subst);
    }
    try writeStep(a, cur, path.steps[path.steps.len - 1], v, subst);
}

fn descend(a: std.mem.Allocator, cur: *AttributeValue, step: parser.PathStep, subst: *const Subst) EvalError!*AttributeValue {
    switch (step) {
        .attr => |name_tok| {
            if (cur.* != .M) cur.* = .{ .M = .empty };
            const name = try subst.resolveName(name_tok);
            if (!cur.M.contains(name)) try cur.M.put(a, try a.dupe(u8, name), .{ .M = .empty });
            return cur.M.getPtr(name).?;
        },
        .index => |idx| {
            if (cur.* != .L or idx >= cur.L.len) return error.Validation;
            return &cur.L[idx];
        },
    }
}

fn writeStep(a: std.mem.Allocator, cur: *AttributeValue, step: parser.PathStep, v: AttributeValue, subst: *const Subst) EvalError!void {
    switch (step) {
        .attr => |name_tok| {
            if (cur.* != .M) cur.* = .{ .M = .empty };
            const name = try subst.resolveName(name_tok);
            try cur.M.put(a, try a.dupe(u8, name), v);
        },
        .index => |idx| {
            if (cur.* != .L or idx >= cur.L.len) return error.Validation;
            cur.L[idx] = v;
        },
    }
}

fn removeAtPath(item: *Item, path: Path, subst: *const Subst) EvalError!void {
    const root = try subst.resolveName(path.root);
    if (path.steps.len == 0) {
        _ = item.attrs.orderedRemove(root);
        return;
    }
    var cur = item.attrs.getPtr(root) orelse return;
    for (path.steps[0 .. path.steps.len - 1]) |step| {
        cur = (try navStepPtr(cur, step, subst)) orelse return;
    }
    switch (path.steps[path.steps.len - 1]) {
        .attr => |name_tok| {
            if (cur.* == .M) _ = cur.M.orderedRemove(try subst.resolveName(name_tok));
        },
        .index => |idx| {
            if (cur.* == .L and idx < cur.L.len) {
                const old = cur.L;
                var i = idx;
                while (i + 1 < old.len) : (i += 1) old[i] = old[i + 1];
                cur.* = .{ .L = old[0 .. old.len - 1] };
            }
        },
    }
}

fn navStepPtr(cur: *AttributeValue, step: parser.PathStep, subst: *const Subst) EvalError!?*AttributeValue {
    switch (step) {
        .attr => |name_tok| {
            if (cur.* != .M) return null;
            return cur.M.getPtr(try subst.resolveName(name_tok));
        },
        .index => |idx| {
            if (cur.* != .L or idx >= cur.L.len) return null;
            return &cur.L[idx];
        },
    }
}

fn applyAdd(a: std.mem.Allocator, item: *Item, path: Path, operand: AttributeValue, subst: *const Subst) EvalError!void {
    const existing = try resolvePath(item.*, path, subst);
    if (existing == null) {
        try setAtPath(a, item, path, try item_store.cloneValue(a, operand), subst);
        return;
    }
    const cur = existing.?;
    if (cur == .N and operand == .N) {
        try setAtPath(a, item, path, .{ .N = try addNumbers(a, cur.N, operand.N) }, subst);
        return;
    }
    if (cur == .SS and operand == .SS) {
        try setAtPath(a, item, path, .{ .SS = try unionSets(a, cur.SS, operand.SS, false) }, subst);
        return;
    }
    if (cur == .NS and operand == .NS) {
        try setAtPath(a, item, path, .{ .NS = try unionSets(a, cur.NS, operand.NS, true) }, subst);
        return;
    }
    if (cur == .BS and operand == .BS) {
        try setAtPath(a, item, path, .{ .BS = try unionSets(a, cur.BS, operand.BS, false) }, subst);
        return;
    }
    return error.Validation;
}

fn applyDelete(a: std.mem.Allocator, item: *Item, path: Path, operand: AttributeValue, subst: *const Subst) EvalError!void {
    const existing = (try resolvePath(item.*, path, subst)) orelse return;
    const result: ?AttributeValue = switch (existing) {
        .SS => if (operand == .SS) try diffSet(a, existing.SS, operand.SS, false, .SS) else return error.Validation,
        .NS => if (operand == .NS) try diffSet(a, existing.NS, operand.NS, true, .NS) else return error.Validation,
        .BS => if (operand == .BS) try diffSet(a, existing.BS, operand.BS, false, .BS) else return error.Validation,
        else => return error.Validation,
    };
    if (result) |r| {
        try setAtPath(a, item, path, r, subst);
    } else {
        try removeAtPath(item, path, subst);
    }
}

fn setMember(set: []const []const u8, needle: []const u8, numeric: bool) bool {
    for (set) |e| {
        if (numeric) {
            if (types.compareNumber(e, needle) == .eq) return true;
        } else if (std.mem.eql(u8, e, needle)) return true;
    }
    return false;
}

fn unionSets(a: std.mem.Allocator, base: []const []const u8, add: []const []const u8, numeric: bool) EvalError![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (base) |e| try out.append(a, try a.dupe(u8, e));
    for (add) |e| {
        if (!setMember(out.items, e, numeric)) try out.append(a, try a.dupe(u8, e));
    }
    return out.toOwnedSlice(a);
}

// Returns the remaining set, or null if it became empty (attribute should drop).
fn diffSet(a: std.mem.Allocator, base: []const []const u8, remove: []const []const u8, numeric: bool, comptime tag: std.meta.Tag(AttributeValue)) EvalError!?AttributeValue {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (base) |e| {
        if (!setMember(remove, e, numeric)) try out.append(a, try a.dupe(u8, e));
    }
    if (out.items.len == 0) return null;
    return @unionInit(AttributeValue, @tagName(tag), try out.toOwnedSlice(a));
}

// ---- decimal arithmetic on canonical number strings ----

const Dec = struct { neg: bool, int: []const u8, frac: []const u8 };

fn splitDecimal(a: std.mem.Allocator, raw: []const u8) EvalError!Dec {
    const canon = types.canonicalizeNumber(a, raw) catch return error.Validation;
    var s = canon;
    var neg = false;
    if (s.len > 0 and s[0] == '-') {
        neg = true;
        s = s[1..];
    }
    const dot = std.mem.indexOfScalar(u8, s, '.');
    if (dot) |d| return .{ .neg = neg, .int = s[0..d], .frac = s[d + 1 ..] };
    return .{ .neg = neg, .int = s, .frac = "" };
}

pub fn addNumbers(a: std.mem.Allocator, x: []const u8, y: []const u8) EvalError![]u8 {
    return combine(a, try splitDecimal(a, x), try splitDecimal(a, y), false);
}

pub fn subNumbers(a: std.mem.Allocator, x: []const u8, y: []const u8) EvalError![]u8 {
    return combine(a, try splitDecimal(a, x), try splitDecimal(a, y), true);
}

fn combine(a: std.mem.Allocator, lhs: Dec, rhs_in: Dec, subtract: bool) EvalError![]u8 {
    var rhs = rhs_in;
    if (subtract) rhs.neg = !rhs.neg;

    const frac_len = @max(lhs.frac.len, rhs.frac.len);
    const lm = try magnitude(a, lhs, frac_len);
    const rm = try magnitude(a, rhs, frac_len);

    var res_neg: bool = undefined;
    var mag: []const u8 = undefined;
    if (lhs.neg == rhs.neg) {
        mag = try addMag(a, lm, rm);
        res_neg = lhs.neg;
    } else {
        const ord = cmpMag(lm, rm);
        if (ord == .eq) {
            return a.dupe(u8, "0");
        } else if (ord == .gt) {
            mag = try subMag(a, lm, rm);
            res_neg = lhs.neg;
        } else {
            mag = try subMag(a, rm, lm);
            res_neg = rhs.neg;
        }
    }
    return placeDecimal(a, mag, frac_len, res_neg);
}

// Concatenate int+frac (frac right-padded to frac_len) into one magnitude digit
// string with leading zeros stripped.
fn magnitude(a: std.mem.Allocator, d: Dec, frac_len: usize) EvalError![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(a, d.int);
    try buf.appendSlice(a, d.frac);
    var pad = frac_len - d.frac.len;
    while (pad > 0) : (pad -= 1) try buf.append(a, '0');
    return stripLeading(buf.items);
}

fn stripLeading(s: []u8) []u8 {
    var i: usize = 0;
    while (i + 1 < s.len and s[i] == '0') i += 1;
    return s[i..];
}

fn cmpMag(x: []const u8, y: []const u8) std.math.Order {
    if (x.len != y.len) return std.math.order(x.len, y.len);
    return std.mem.order(u8, x, y);
}

fn addMag(a: std.mem.Allocator, x: []const u8, y: []const u8) EvalError![]u8 {
    const n = @max(x.len, y.len) + 1;
    const out = try a.alloc(u8, n);
    var carry: u8 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var sum: u8 = carry;
        if (i < x.len) sum += x[x.len - 1 - i] - '0';
        if (i < y.len) sum += y[y.len - 1 - i] - '0';
        out[n - 1 - i] = '0' + (sum % 10);
        carry = sum / 10;
    }
    return stripLeading(out);
}

// Requires x >= y (by magnitude).
fn subMag(a: std.mem.Allocator, x: []const u8, y: []const u8) EvalError![]u8 {
    const out = try a.alloc(u8, x.len);
    var borrow: i16 = 0;
    var i: usize = 0;
    while (i < x.len) : (i += 1) {
        var diff: i16 = @as(i16, x[x.len - 1 - i] - '0') - borrow;
        if (i < y.len) diff -= @as(i16, y[y.len - 1 - i] - '0');
        if (diff < 0) {
            diff += 10;
            borrow = 1;
        } else borrow = 0;
        out[x.len - 1 - i] = '0' + @as(u8, @intCast(diff));
    }
    return stripLeading(out);
}

fn placeDecimal(a: std.mem.Allocator, mag_in: []const u8, frac_len: usize, neg: bool) EvalError![]u8 {
    var mag = mag_in;
    if (mag.len == 0) mag = "0";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (frac_len == 0) {
        try buf.appendSlice(a, mag);
    } else {
        // ensure at least frac_len+1 digits so there's an integer part
        var padded: std.ArrayListUnmanaged(u8) = .empty;
        var pad = if (mag.len <= frac_len) frac_len + 1 - mag.len else 0;
        while (pad > 0) : (pad -= 1) try padded.append(a, '0');
        try padded.appendSlice(a, mag);
        const digits = padded.items;
        const split = digits.len - frac_len;
        try buf.appendSlice(a, digits[0..split]);
        try buf.append(a, '.');
        try buf.appendSlice(a, digits[split..]);
    }
    // canonicalize away trailing zeros / lone dot via types helper
    const pre = if (neg) try std.fmt.allocPrint(a, "-{s}", .{buf.items}) else buf.items;
    return types.canonicalizeNumber(a, pre) catch error.Validation;
}

// ---- projection ----

// Copy the top-level attributes referenced by the projection paths. Nested and
// indexed paths copy their whole root attribute (over-inclusive but never wrong
// for the common top-level case).
pub fn project(a: std.mem.Allocator, proj: parser.Projection, item: Item, subst: *const Subst) EvalError!Item {
    var out: Item = .{};
    for (proj.paths) |p| {
        const root = try subst.resolveName(p.root);
        if (out.attrs.contains(root)) continue;
        if (item.attrs.get(root)) |v| {
            try out.attrs.put(a, try a.dupe(u8, root), try item_store.cloneValue(a, v));
        }
    }
    return out;
}

// ---- tests ----

const testing = std.testing;

fn mkSubst(a: std.mem.Allocator, names: anytype, values: anytype) !Subst {
    var s: Subst = .{};
    inline for (names) |pair| try s.names.put(a, pair[0], pair[1]);
    inline for (values) |pair| try s.values.put(a, pair[0], pair[1]);
    return s;
}

test "evalBool comparison with substitution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var item: Item = .{};
    try item.attrs.put(a, "name", .{ .S = "x" });
    var subst = try mkSubst(a, .{.{ "#a", "name" }}, .{.{ ":v", AttributeValue{ .S = "x" } }});
    const e = try parser.parseCondition(a, "#a = :v");
    try testing.expect(try evalBool(a, e, item, &subst));
    const e2 = try parser.parseCondition(a, "#a <> :v");
    try testing.expect(!(try evalBool(a, e2, item, &subst)));
}

test "evalBool attribute_exists / not_exists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var item: Item = .{};
    try item.attrs.put(a, "id", .{ .S = "1" });
    var subst: Subst = .{};
    try testing.expect(try evalBool(a, try parser.parseCondition(a, "attribute_exists(id)"), item, &subst));
    try testing.expect(try evalBool(a, try parser.parseCondition(a, "attribute_not_exists(missing)"), item, &subst));
    try testing.expect(!(try evalBool(a, try parser.parseCondition(a, "attribute_not_exists(id)"), item, &subst)));
}

test "evalBool between, in, size, begins_with, contains" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var item: Item = .{};
    try item.attrs.put(a, "age", .{ .N = "30" });
    try item.attrs.put(a, "name", .{ .S = "alice" });
    var tags = [_][]const u8{ "x", "y" };
    try item.attrs.put(a, "tags", .{ .SS = &tags });
    var subst = try mkSubst(a, .{}, .{
        .{ ":lo", AttributeValue{ .N = "20" } },
        .{ ":hi", AttributeValue{ .N = "40" } },
        .{ ":n", AttributeValue{ .N = "3" } },
        .{ ":p", AttributeValue{ .S = "al" } },
        .{ ":t", AttributeValue{ .S = "x" } },
        .{ ":a", AttributeValue{ .N = "30" } },
    });
    try testing.expect(try evalBool(a, try parser.parseCondition(a, "age BETWEEN :lo AND :hi"), item, &subst));
    try testing.expect(try evalBool(a, try parser.parseCondition(a, "age IN (:lo, :a)"), item, &subst));
    try testing.expect(try evalBool(a, try parser.parseCondition(a, "size(name) > :n"), item, &subst));
    try testing.expect(try evalBool(a, try parser.parseCondition(a, "begins_with(name, :p)"), item, &subst));
    try testing.expect(try evalBool(a, try parser.parseCondition(a, "contains(tags, :t)"), item, &subst));
}

test "evalBool path access nested and indexed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var addr: std.StringArrayHashMapUnmanaged(AttributeValue) = .empty;
    try addr.put(a, "zip", .{ .S = "94103" });
    var item: Item = .{};
    try item.attrs.put(a, "address", .{ .M = addr });
    var list = [_]AttributeValue{ .{ .S = "a" }, .{ .S = "b" }, .{ .S = "c" } };
    try item.attrs.put(a, "tags", .{ .L = &list });
    var subst = try mkSubst(a, .{}, .{
        .{ ":z", AttributeValue{ .S = "94103" } },
        .{ ":c", AttributeValue{ .S = "c" } },
    });
    try testing.expect(try evalBool(a, try parser.parseCondition(a, "address.zip = :z"), item, &subst));
    try testing.expect(try evalBool(a, try parser.parseCondition(a, "tags[2] = :c"), item, &subst));
}

test "undefined name/value rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var item: Item = .{};
    try item.attrs.put(a, "id", .{ .S = "1" });
    var subst: Subst = .{};
    try testing.expectError(error.Validation, evalBool(a, try parser.parseCondition(a, "#x = :v"), item, &subst));
    try testing.expectError(error.Validation, evalBool(a, try parser.parseCondition(a, "id = :missing"), item, &subst));
}

test "applyUpdate SET arithmetic on missing creates a=1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var subst = try mkSubst(a, .{}, .{.{ ":one", AttributeValue{ .N = "1" } }});
    // emulate "SET a = if_not_exists(a, :zero) + :one" pattern with ADD instead
    const prog = try parser.parseUpdate(a, "ADD a :one");
    const res = try applyUpdate(a, prog, null, &subst);
    try testing.expectEqualStrings("1", res.after.attrs.get("a").?.N);
    const res2 = try applyUpdate(a, prog, res.after, &subst);
    try testing.expectEqualStrings("2", res2.after.attrs.get("a").?.N);
}

test "applyUpdate SET if_not_exists and list_append" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var empty_list = [_]AttributeValue{};
    var new_list = [_]AttributeValue{.{ .S = "z" }};
    var subst = try mkSubst(a, .{}, .{
        .{ ":d", AttributeValue{ .N = "5" } },
        .{ ":new", AttributeValue{ .L = &new_list } },
        .{ ":init", AttributeValue{ .L = &empty_list } },
    });
    const r1 = try applyUpdate(a, try parser.parseUpdate(a, "SET age = if_not_exists(age, :d)"), null, &subst);
    try testing.expectEqualStrings("5", r1.after.attrs.get("age").?.N);

    const r2 = try applyUpdate(a, try parser.parseUpdate(a, "SET items = list_append(if_not_exists(items, :init), :new)"), null, &subst);
    try testing.expectEqual(@as(usize, 1), r2.after.attrs.get("items").?.L.len);
}

test "applyUpdate REMOVE and arithmetic plus/minus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var item: Item = .{};
    try item.attrs.put(a, "n", .{ .N = "10" });
    try item.attrs.put(a, "x", .{ .S = "drop" });
    var subst = try mkSubst(a, .{}, .{ .{ ":d", AttributeValue{ .N = "3" } }, .{ ":d2", AttributeValue{ .N = "2.5" } } });
    const r = try applyUpdate(a, try parser.parseUpdate(a, "SET n = n - :d REMOVE x"), item, &subst);
    try testing.expectEqualStrings("7", r.after.attrs.get("n").?.N);
    try testing.expect(r.after.attrs.get("x") == null);

    const r2 = try applyUpdate(a, try parser.parseUpdate(a, "SET n = n + :d2"), item, &subst);
    try testing.expectEqualStrings("12.5", r2.after.attrs.get("n").?.N);
}

test "decimal add/sub correctness" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("3", try addNumbers(a, "1", "2"));
    try testing.expectEqualStrings("100", try addNumbers(a, "99", "1"));
    try testing.expectEqualStrings("12.5", try addNumbers(a, "10", "2.5"));
    try testing.expectEqualStrings("0", try subNumbers(a, "5", "5"));
    try testing.expectEqualStrings("-3", try subNumbers(a, "2", "5"));
    try testing.expectEqualStrings("0.75", try subNumbers(a, "1.25", "0.5"));
    try testing.expectEqualStrings("1.5", try addNumbers(a, "0.5", "1.0"));
}

test "ADD set union and DELETE set diff" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ss = [_][]const u8{ "a", "b" };
    var item: Item = .{};
    try item.attrs.put(a, "s", .{ .SS = &ss });
    var add_set = [_][]const u8{ "b", "c" };
    var del_set = [_][]const u8{"a"};
    var subst = try mkSubst(a, .{}, .{ .{ ":add", AttributeValue{ .SS = &add_set } }, .{ ":del", AttributeValue{ .SS = &del_set } } });
    const r = try applyUpdate(a, try parser.parseUpdate(a, "ADD s :add"), item, &subst);
    try testing.expectEqual(@as(usize, 3), r.after.attrs.get("s").?.SS.len);
    const r2 = try applyUpdate(a, try parser.parseUpdate(a, "DELETE s :del"), item, &subst);
    try testing.expectEqual(@as(usize, 1), r2.after.attrs.get("s").?.SS.len);
}

test "project keeps only referenced roots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var item: Item = .{};
    try item.attrs.put(a, "id", .{ .S = "1" });
    try item.attrs.put(a, "name", .{ .S = "x" });
    try item.attrs.put(a, "secret", .{ .S = "z" });
    var subst: Subst = .{};
    const proj = try parser.parseProjection(a, "id, name");
    const out = try project(a, proj, item, &subst);
    try testing.expectEqual(@as(usize, 2), out.attrs.count());
    try testing.expect(out.attrs.get("secret") == null);
}
