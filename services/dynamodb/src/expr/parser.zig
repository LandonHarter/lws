const std = @import("std");
const lexer = @import("lexer.zig");

const Token = lexer.Token;
const TokKind = lexer.TokKind;

pub const ParseError = error{ ParseFailed, OutOfMemory, InvalidToken };

// ---- AST ----

pub const PathStep = union(enum) {
    attr: []const u8, // .name or #ref token
    index: usize, // [i]
};

// An attribute path: a root name token followed by dotted/indexed steps. Name
// tokens keep their raw form (`#ref` or a literal name); the evaluator resolves
// `#ref` against ExpressionAttributeNames.
pub const Path = struct {
    root: []const u8,
    steps: []PathStep = &.{},
};

pub const Comparator = enum { eq, ne, lt, le, gt, ge };

// A value-producing operand inside a condition/filter.
pub const Operand = union(enum) {
    path: Path,
    value: []const u8, // `:ref` token
    size: Path, // size(path) — yields a number
};

pub const BoolExpr = union(enum) {
    compare: struct { op: Comparator, lhs: Operand, rhs: Operand },
    between: struct { val: Operand, lo: Operand, hi: Operand },
    in_set: struct { val: Operand, set: []Operand },
    attribute_exists: Path,
    attribute_not_exists: Path,
    attribute_type: struct { path: Path, type_ref: []const u8 }, // `:ref` token
    begins_with: struct { path: Path, prefix: Operand },
    contains: struct { path: Path, operand: Operand },
    and_: struct { lhs: *BoolExpr, rhs: *BoolExpr },
    or_: struct { lhs: *BoolExpr, rhs: *BoolExpr },
    not_: *BoolExpr,
};

// ---- Update program ----

pub const UpdOperand = union(enum) {
    path: Path,
    value: []const u8, // `:ref`
    if_not_exists: struct { path: Path, default: *UpdOperand },
    list_append: struct { lhs: *UpdOperand, rhs: *UpdOperand },
};

pub const SetValue = union(enum) {
    operand: UpdOperand,
    plus: struct { lhs: UpdOperand, rhs: UpdOperand },
    minus: struct { lhs: UpdOperand, rhs: UpdOperand },
};

pub const UpdateClause = union(enum) {
    set: struct { path: Path, value: SetValue },
    remove: Path,
    add: struct { path: Path, value: []const u8 }, // `:ref`
    delete: struct { path: Path, value: []const u8 }, // `:ref`
};

pub const UpdateProgram = struct {
    clauses: []UpdateClause = &.{},
};

// ---- KeyCondition ----

pub const KeySortOp = enum { eq, lt, le, gt, ge, between, begins_with };

pub const KeySortCond = struct {
    name: []const u8, // path root token (no steps allowed on key attrs)
    op: KeySortOp,
    a: []const u8, // `:ref`
    b: ?[]const u8 = null, // `:ref` (BETWEEN upper)
};

pub const KeyCondition = struct {
    pk_name: []const u8,
    pk_value: []const u8, // `:ref`
    sort: ?KeySortCond = null,
};

pub const Projection = struct {
    paths: []Path = &.{},
};

// ---- Parser ----

const Parser = struct {
    a: std.mem.Allocator,
    toks: []Token,
    i: usize = 0,

    fn peek(self: *Parser) Token {
        return self.toks[self.i];
    }

    fn advance(self: *Parser) Token {
        const t = self.toks[self.i];
        if (self.i + 1 < self.toks.len) self.i += 1;
        return t;
    }

    fn eat(self: *Parser, k: TokKind) ParseError!Token {
        if (self.toks[self.i].kind != k) return error.ParseFailed;
        return self.advance();
    }

    fn atEof(self: *Parser) bool {
        return self.toks[self.i].kind == .eof;
    }

    fn isKeyword(t: Token, word: []const u8) bool {
        return t.kind == .ident and std.ascii.eqlIgnoreCase(t.text, word);
    }

    fn create(self: *Parser, comptime T: type, val: T) ParseError!*T {
        const p = try self.a.create(T);
        p.* = val;
        return p;
    }

    // ---- paths ----

    fn parsePath(self: *Parser) ParseError!Path {
        const head = self.peek();
        if (head.kind != .ident and head.kind != .name_ref) return error.ParseFailed;
        _ = self.advance();
        var steps: std.ArrayListUnmanaged(PathStep) = .empty;
        while (true) {
            const t = self.peek();
            if (t.kind == .dot) {
                _ = self.advance();
                const seg = self.peek();
                if (seg.kind != .ident and seg.kind != .name_ref) return error.ParseFailed;
                _ = self.advance();
                try steps.append(self.a, .{ .attr = seg.text });
            } else if (t.kind == .lbracket) {
                _ = self.advance();
                const num = try self.eat(.number);
                const idx = std.fmt.parseInt(usize, num.text, 10) catch return error.ParseFailed;
                _ = try self.eat(.rbracket);
                try steps.append(self.a, .{ .index = idx });
            } else break;
        }
        return .{ .root = head.text, .steps = try steps.toOwnedSlice(self.a) };
    }

    // ---- condition / filter ----

    fn parseCondition(self: *Parser) ParseError!*BoolExpr {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!*BoolExpr {
        var lhs = try self.parseAnd();
        while (isKeyword(self.peek(), "OR")) {
            _ = self.advance();
            const rhs = try self.parseAnd();
            lhs = try self.create(BoolExpr, .{ .or_ = .{ .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseAnd(self: *Parser) ParseError!*BoolExpr {
        var lhs = try self.parseNot();
        while (isKeyword(self.peek(), "AND")) {
            _ = self.advance();
            const rhs = try self.parseNot();
            lhs = try self.create(BoolExpr, .{ .and_ = .{ .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseNot(self: *Parser) ParseError!*BoolExpr {
        if (isKeyword(self.peek(), "NOT")) {
            _ = self.advance();
            const inner = try self.parseNot();
            return self.create(BoolExpr, .{ .not_ = inner });
        }
        return self.parsePredicate();
    }

    fn boolFunc(t: Token) ?[]const u8 {
        if (t.kind != .ident) return null;
        const names = [_][]const u8{ "attribute_exists", "attribute_not_exists", "attribute_type", "begins_with", "contains" };
        for (names) |n| if (std.ascii.eqlIgnoreCase(t.text, n)) return n;
        return null;
    }

    fn parsePredicate(self: *Parser) ParseError!*BoolExpr {
        const t = self.peek();
        if (t.kind == .lparen) {
            _ = self.advance();
            const inner = try self.parseOr();
            _ = try self.eat(.rparen);
            return inner;
        }
        if (boolFunc(t)) |fname| {
            if (self.toks[self.i + 1].kind == .lparen) {
                return self.parseBoolFunc(fname);
            }
        }
        // operand followed by comparator / BETWEEN / IN
        const lhs = try self.parseOperand();
        const nt = self.peek();
        switch (nt.kind) {
            .eq, .ne, .lt, .le, .gt, .ge => {
                _ = self.advance();
                const rhs = try self.parseOperand();
                return self.create(BoolExpr, .{ .compare = .{ .op = cmpOf(nt.kind), .lhs = lhs, .rhs = rhs } });
            },
            else => {},
        }
        if (isKeyword(nt, "BETWEEN")) {
            _ = self.advance();
            const lo = try self.parseOperand();
            if (!isKeyword(self.peek(), "AND")) return error.ParseFailed;
            _ = self.advance();
            const hi = try self.parseOperand();
            return self.create(BoolExpr, .{ .between = .{ .val = lhs, .lo = lo, .hi = hi } });
        }
        if (isKeyword(nt, "IN")) {
            _ = self.advance();
            _ = try self.eat(.lparen);
            var set: std.ArrayListUnmanaged(Operand) = .empty;
            try set.append(self.a, try self.parseOperand());
            while (self.peek().kind == .comma) {
                _ = self.advance();
                try set.append(self.a, try self.parseOperand());
            }
            _ = try self.eat(.rparen);
            return self.create(BoolExpr, .{ .in_set = .{ .val = lhs, .set = try set.toOwnedSlice(self.a) } });
        }
        return error.ParseFailed;
    }

    fn cmpOf(k: TokKind) Comparator {
        return switch (k) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => unreachable,
        };
    }

    fn parseBoolFunc(self: *Parser, fname: []const u8) ParseError!*BoolExpr {
        _ = self.advance(); // function name
        _ = try self.eat(.lparen);
        if (std.ascii.eqlIgnoreCase(fname, "attribute_exists")) {
            const p = try self.parsePath();
            _ = try self.eat(.rparen);
            return self.create(BoolExpr, .{ .attribute_exists = p });
        } else if (std.ascii.eqlIgnoreCase(fname, "attribute_not_exists")) {
            const p = try self.parsePath();
            _ = try self.eat(.rparen);
            return self.create(BoolExpr, .{ .attribute_not_exists = p });
        } else if (std.ascii.eqlIgnoreCase(fname, "attribute_type")) {
            const p = try self.parsePath();
            _ = try self.eat(.comma);
            const v = try self.eat(.value_ref);
            _ = try self.eat(.rparen);
            return self.create(BoolExpr, .{ .attribute_type = .{ .path = p, .type_ref = v.text } });
        } else if (std.ascii.eqlIgnoreCase(fname, "begins_with")) {
            const p = try self.parsePath();
            _ = try self.eat(.comma);
            const op = try self.parseOperand();
            _ = try self.eat(.rparen);
            return self.create(BoolExpr, .{ .begins_with = .{ .path = p, .prefix = op } });
        } else { // contains
            const p = try self.parsePath();
            _ = try self.eat(.comma);
            const op = try self.parseOperand();
            _ = try self.eat(.rparen);
            return self.create(BoolExpr, .{ .contains = .{ .path = p, .operand = op } });
        }
    }

    fn parseOperand(self: *Parser) ParseError!Operand {
        const t = self.peek();
        if (t.kind == .value_ref) {
            _ = self.advance();
            return .{ .value = t.text };
        }
        if (t.kind == .ident and std.ascii.eqlIgnoreCase(t.text, "size") and self.toks[self.i + 1].kind == .lparen) {
            _ = self.advance(); // size
            _ = try self.eat(.lparen);
            const p = try self.parsePath();
            _ = try self.eat(.rparen);
            return .{ .size = p };
        }
        const p = try self.parsePath();
        return .{ .path = p };
    }

    // ---- update ----

    fn parseUpdate(self: *Parser) ParseError!UpdateProgram {
        var clauses: std.ArrayListUnmanaged(UpdateClause) = .empty;
        while (!self.atEof()) {
            const kw = self.peek();
            if (isKeyword(kw, "SET")) {
                _ = self.advance();
                try self.parseSetClauses(&clauses);
            } else if (isKeyword(kw, "REMOVE")) {
                _ = self.advance();
                try self.parseRemoveClauses(&clauses);
            } else if (isKeyword(kw, "ADD")) {
                _ = self.advance();
                try self.parseAddDeleteClauses(&clauses, true);
            } else if (isKeyword(kw, "DELETE")) {
                _ = self.advance();
                try self.parseAddDeleteClauses(&clauses, false);
            } else return error.ParseFailed;
        }
        return .{ .clauses = try clauses.toOwnedSlice(self.a) };
    }

    fn atClauseBoundary(self: *Parser) bool {
        const t = self.peek();
        return t.kind == .eof or isKeyword(t, "SET") or isKeyword(t, "REMOVE") or isKeyword(t, "ADD") or isKeyword(t, "DELETE");
    }

    fn parseSetClauses(self: *Parser, clauses: *std.ArrayListUnmanaged(UpdateClause)) ParseError!void {
        while (true) {
            const path = try self.parsePath();
            _ = try self.eat(.eq);
            const v = try self.parseSetValue();
            try clauses.append(self.a, .{ .set = .{ .path = path, .value = v } });
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
    }

    fn parseSetValue(self: *Parser) ParseError!SetValue {
        const lhs = try self.parseUpdOperand();
        const t = self.peek();
        if (t.kind == .plus) {
            _ = self.advance();
            const rhs = try self.parseUpdOperand();
            return .{ .plus = .{ .lhs = lhs, .rhs = rhs } };
        }
        if (t.kind == .minus) {
            _ = self.advance();
            const rhs = try self.parseUpdOperand();
            return .{ .minus = .{ .lhs = lhs, .rhs = rhs } };
        }
        return .{ .operand = lhs };
    }

    fn parseUpdOperand(self: *Parser) ParseError!UpdOperand {
        const t = self.peek();
        if (t.kind == .value_ref) {
            _ = self.advance();
            return .{ .value = t.text };
        }
        if (t.kind == .ident and std.ascii.eqlIgnoreCase(t.text, "if_not_exists") and self.toks[self.i + 1].kind == .lparen) {
            _ = self.advance();
            _ = try self.eat(.lparen);
            const p = try self.parsePath();
            _ = try self.eat(.comma);
            const def = try self.parseUpdOperand();
            _ = try self.eat(.rparen);
            const dp = try self.create(UpdOperand, def);
            return .{ .if_not_exists = .{ .path = p, .default = dp } };
        }
        if (t.kind == .ident and std.ascii.eqlIgnoreCase(t.text, "list_append") and self.toks[self.i + 1].kind == .lparen) {
            _ = self.advance();
            _ = try self.eat(.lparen);
            const a1 = try self.parseUpdOperand();
            _ = try self.eat(.comma);
            const a2 = try self.parseUpdOperand();
            _ = try self.eat(.rparen);
            const lp = try self.create(UpdOperand, a1);
            const rp = try self.create(UpdOperand, a2);
            return .{ .list_append = .{ .lhs = lp, .rhs = rp } };
        }
        const p = try self.parsePath();
        return .{ .path = p };
    }

    fn parseRemoveClauses(self: *Parser, clauses: *std.ArrayListUnmanaged(UpdateClause)) ParseError!void {
        while (true) {
            const path = try self.parsePath();
            try clauses.append(self.a, .{ .remove = path });
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
    }

    fn parseAddDeleteClauses(self: *Parser, clauses: *std.ArrayListUnmanaged(UpdateClause), is_add: bool) ParseError!void {
        while (true) {
            const path = try self.parsePath();
            const v = try self.eat(.value_ref);
            if (is_add) {
                try clauses.append(self.a, .{ .add = .{ .path = path, .value = v.text } });
            } else {
                try clauses.append(self.a, .{ .delete = .{ .path = path, .value = v.text } });
            }
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
    }

    // ---- key condition ----

    fn parseKeyCondition(self: *Parser) ParseError!KeyCondition {
        const first = try self.parseKeyPredicate();
        var kc: KeyCondition = undefined;
        // The partition predicate must be a simple equality on a bare name.
        if (first.op != .eq) return error.ParseFailed;
        kc = .{ .pk_name = first.name, .pk_value = first.a };
        if (isKeyword(self.peek(), "AND")) {
            _ = self.advance();
            const second = try self.parseKeyPredicate();
            kc.sort = .{ .name = second.name, .op = second.op, .a = second.a, .b = second.b };
        }
        if (!self.atEof()) return error.ParseFailed;
        return kc;
    }

    const KeyPred = struct {
        name: []const u8,
        op: KeySortOp,
        a: []const u8,
        b: ?[]const u8 = null,
    };

    fn parseKeyPredicate(self: *Parser) ParseError!KeyPred {
        // begins_with(name, :v)
        if (self.peek().kind == .ident and std.ascii.eqlIgnoreCase(self.peek().text, "begins_with") and self.toks[self.i + 1].kind == .lparen) {
            _ = self.advance();
            _ = try self.eat(.lparen);
            const name = try self.parseKeyName();
            _ = try self.eat(.comma);
            const v = try self.eat(.value_ref);
            _ = try self.eat(.rparen);
            return .{ .name = name, .op = .begins_with, .a = v.text };
        }
        const name = try self.parseKeyName();
        const t = self.peek();
        switch (t.kind) {
            .eq, .lt, .le, .gt, .ge => {
                _ = self.advance();
                const v = try self.eat(.value_ref);
                return .{ .name = name, .op = sortOpOf(t.kind), .a = v.text };
            },
            else => {},
        }
        if (isKeyword(t, "BETWEEN")) {
            _ = self.advance();
            const lo = try self.eat(.value_ref);
            if (!isKeyword(self.peek(), "AND")) return error.ParseFailed;
            _ = self.advance();
            const hi = try self.eat(.value_ref);
            return .{ .name = name, .op = .between, .a = lo.text, .b = hi.text };
        }
        return error.ParseFailed;
    }

    // Key attributes are bare names or #refs with no dotted/index steps.
    fn parseKeyName(self: *Parser) ParseError![]const u8 {
        const t = self.peek();
        if (t.kind != .ident and t.kind != .name_ref) return error.ParseFailed;
        _ = self.advance();
        return t.text;
    }

    fn sortOpOf(k: TokKind) KeySortOp {
        return switch (k) {
            .eq => .eq,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => unreachable,
        };
    }

    fn parseProjection(self: *Parser) ParseError!Projection {
        var paths: std.ArrayListUnmanaged(Path) = .empty;
        try paths.append(self.a, try self.parsePath());
        while (self.peek().kind == .comma) {
            _ = self.advance();
            try paths.append(self.a, try self.parsePath());
        }
        if (!self.atEof()) return error.ParseFailed;
        return .{ .paths = try paths.toOwnedSlice(self.a) };
    }
};

fn lexAll(a: std.mem.Allocator, input: []const u8) ParseError![]Token {
    var lx = lexer.Lexer.init(input);
    return lx.tokenize(a);
}

// ---- public entry points ----

pub fn parseCondition(a: std.mem.Allocator, input: []const u8) ParseError!*BoolExpr {
    var p: Parser = .{ .a = a, .toks = try lexAll(a, input) };
    const node = try p.parseCondition();
    if (!p.atEof()) return error.ParseFailed;
    return node;
}

pub fn parseFilter(a: std.mem.Allocator, input: []const u8) ParseError!*BoolExpr {
    return parseCondition(a, input);
}

pub fn parseUpdate(a: std.mem.Allocator, input: []const u8) ParseError!UpdateProgram {
    var p: Parser = .{ .a = a, .toks = try lexAll(a, input) };
    return p.parseUpdate();
}

pub fn parseKeyCondition(a: std.mem.Allocator, input: []const u8) ParseError!KeyCondition {
    var p: Parser = .{ .a = a, .toks = try lexAll(a, input) };
    return p.parseKeyCondition();
}

pub fn parseProjection(a: std.mem.Allocator, input: []const u8) ParseError!Projection {
    var p: Parser = .{ .a = a, .toks = try lexAll(a, input) };
    return p.parseProjection();
}

const testing = std.testing;

test "parse simple comparison" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const e = try parseCondition(arena.allocator(), "#a = :v");
    try testing.expect(e.* == .compare);
    try testing.expectEqual(Comparator.eq, e.compare.op);
    try testing.expectEqualStrings("#a", e.compare.lhs.path.root);
    try testing.expectEqualStrings(":v", e.compare.rhs.value);
}

test "parse AND/OR precedence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // a = :1 OR b = :2 AND c = :3  =>  a OR (b AND c)
    const e = try parseCondition(arena.allocator(), "a = :1 OR b = :2 AND c = :3");
    try testing.expect(e.* == .or_);
    try testing.expect(e.or_.rhs.* == .and_);
}

test "parse functions and between/in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try parseCondition(a, "attribute_exists(#x)")).* == .attribute_exists);
    try testing.expect((try parseCondition(a, "attribute_not_exists(x)")).* == .attribute_not_exists);
    try testing.expect((try parseCondition(a, "begins_with(x, :p)")).* == .begins_with);
    try testing.expect((try parseCondition(a, "contains(x, :p)")).* == .contains);
    try testing.expect((try parseCondition(a, "attribute_type(x, :t)")).* == .attribute_type);
    try testing.expect((try parseCondition(a, "x BETWEEN :lo AND :hi")).* == .between);
    const in_e = try parseCondition(a, "x IN (:a, :b, :c)");
    try testing.expect(in_e.* == .in_set);
    try testing.expectEqual(@as(usize, 3), in_e.in_set.set.len);
    try testing.expect((try parseCondition(a, "size(#a) > :n")).* == .compare);
}

test "parse update program SET/REMOVE/ADD/DELETE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const prog = try parseUpdate(arena.allocator(), "SET #a = :v, b = b + :one REMOVE c ADD d :n DELETE e :s");
    try testing.expectEqual(@as(usize, 5), prog.clauses.len);
    try testing.expect(prog.clauses[0] == .set);
    try testing.expect(prog.clauses[1].set.value == .plus);
    try testing.expect(prog.clauses[2] == .remove);
    try testing.expect(prog.clauses[3] == .add);
    try testing.expect(prog.clauses[4] == .delete);
}

test "parse update if_not_exists and list_append" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p1 = try parseUpdate(a, "SET #age = if_not_exists(#age, :default)");
    try testing.expect(p1.clauses[0].set.value.operand == .if_not_exists);
    const p2 = try parseUpdate(a, "SET items = list_append(items, :new)");
    try testing.expect(p2.clauses[0].set.value.operand == .list_append);
}

test "parse path with dots and indices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const e = try parseCondition(arena.allocator(), "address.zip = :z");
    const p = e.compare.lhs.path;
    try testing.expectEqualStrings("address", p.root);
    try testing.expectEqual(@as(usize, 1), p.steps.len);
    try testing.expectEqualStrings("zip", p.steps[0].attr);

    const e2 = try parseCondition(arena.allocator(), "tags[2].name = :n");
    const p2 = e2.compare.lhs.path;
    try testing.expectEqual(@as(usize, 2), p2.steps.len);
    try testing.expectEqual(@as(usize, 2), p2.steps[0].index);
    try testing.expectEqualStrings("name", p2.steps[1].attr);
}

test "parse key condition pk only and pk+sort" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kc1 = try parseKeyCondition(a, "#pk = :p");
    try testing.expectEqualStrings("#pk", kc1.pk_name);
    try testing.expect(kc1.sort == null);

    const kc2 = try parseKeyCondition(a, "pk = :p AND begins_with(sk, :s)");
    try testing.expect(kc2.sort != null);
    try testing.expectEqual(KeySortOp.begins_with, kc2.sort.?.op);

    const kc3 = try parseKeyCondition(a, "pk = :p AND sk BETWEEN :lo AND :hi");
    try testing.expectEqual(KeySortOp.between, kc3.sort.?.op);
    try testing.expectEqualStrings(":hi", kc3.sort.?.b.?);
}

test "key condition rejects non-equality partition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ParseFailed, parseKeyCondition(arena.allocator(), "pk < :p"));
}

test "parse projection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proj = try parseProjection(arena.allocator(), "id, address.zip, tags[0]");
    try testing.expectEqual(@as(usize, 3), proj.paths.len);
}

test "reject trailing garbage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ParseFailed, parseCondition(arena.allocator(), "a = :v garbage"));
}
