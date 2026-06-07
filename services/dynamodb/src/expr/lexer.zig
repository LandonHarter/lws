const std = @import("std");

pub const TokKind = enum {
    ident, // bareword [A-Za-z_][A-Za-z0-9_]* — may be a keyword or attribute name
    name_ref, // #foo
    value_ref, // :bar
    number, // digits — only valid inside [i] indices
    eq, // =
    ne, // <>
    lt, // <
    le, // <=
    gt, // >
    ge, // >=
    lparen, // (
    rparen, // )
    lbracket, // [
    rbracket, // ]
    comma, // ,
    dot, // .
    plus, // +
    minus, // -
    eof,
};

pub const Token = struct {
    kind: TokKind,
    text: []const u8, // slice into the source
};

pub const LexError = error{InvalidToken};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src };
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isIdentChar(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    pub fn next(self: *Lexer) LexError!Token {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t' or self.src[self.pos] == '\n' or self.src[self.pos] == '\r')) {
            self.pos += 1;
        }
        if (self.pos >= self.src.len) return .{ .kind = .eof, .text = "" };

        const start = self.pos;
        const c = self.src[self.pos];
        switch (c) {
            '=' => {
                self.pos += 1;
                return .{ .kind = .eq, .text = self.src[start..self.pos] };
            },
            '<' => {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '>') {
                    self.pos += 1;
                    return .{ .kind = .ne, .text = self.src[start..self.pos] };
                }
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return .{ .kind = .le, .text = self.src[start..self.pos] };
                }
                return .{ .kind = .lt, .text = self.src[start..self.pos] };
            },
            '>' => {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return .{ .kind = .ge, .text = self.src[start..self.pos] };
                }
                return .{ .kind = .gt, .text = self.src[start..self.pos] };
            },
            '(' => {
                self.pos += 1;
                return .{ .kind = .lparen, .text = self.src[start..self.pos] };
            },
            ')' => {
                self.pos += 1;
                return .{ .kind = .rparen, .text = self.src[start..self.pos] };
            },
            '[' => {
                self.pos += 1;
                return .{ .kind = .lbracket, .text = self.src[start..self.pos] };
            },
            ']' => {
                self.pos += 1;
                return .{ .kind = .rbracket, .text = self.src[start..self.pos] };
            },
            ',' => {
                self.pos += 1;
                return .{ .kind = .comma, .text = self.src[start..self.pos] };
            },
            '.' => {
                self.pos += 1;
                return .{ .kind = .dot, .text = self.src[start..self.pos] };
            },
            '+' => {
                self.pos += 1;
                return .{ .kind = .plus, .text = self.src[start..self.pos] };
            },
            '-' => {
                self.pos += 1;
                return .{ .kind = .minus, .text = self.src[start..self.pos] };
            },
            '#' => {
                self.pos += 1;
                while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
                if (self.pos - start <= 1) return error.InvalidToken;
                return .{ .kind = .name_ref, .text = self.src[start..self.pos] };
            },
            ':' => {
                self.pos += 1;
                while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
                if (self.pos - start <= 1) return error.InvalidToken;
                return .{ .kind = .value_ref, .text = self.src[start..self.pos] };
            },
            else => {
                if (isIdentStart(c)) {
                    self.pos += 1;
                    while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
                    return .{ .kind = .ident, .text = self.src[start..self.pos] };
                }
                if (isDigit(c)) {
                    self.pos += 1;
                    while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
                    return .{ .kind = .number, .text = self.src[start..self.pos] };
                }
                return error.InvalidToken;
            },
        }
    }

    // Lex the whole source into an owned token slice (terminated by .eof).
    pub fn tokenize(self: *Lexer, a: std.mem.Allocator) ![]Token {
        var out: std.ArrayListUnmanaged(Token) = .empty;
        while (true) {
            const tok = try self.next();
            try out.append(a, tok);
            if (tok.kind == .eof) break;
        }
        return out.toOwnedSlice(a);
    }
};

const testing = std.testing;

test "lex operators and refs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lx = Lexer.init("#a = :v AND size(#b) <= :n");
    const toks = try lx.tokenize(arena.allocator());
    const kinds = [_]TokKind{ .name_ref, .eq, .value_ref, .ident, .ident, .lparen, .name_ref, .rparen, .le, .value_ref, .eof };
    try testing.expectEqual(kinds.len, toks.len);
    for (kinds, toks) |k, t| try testing.expectEqual(k, t.kind);
    try testing.expectEqualStrings("#a", toks[0].text);
    try testing.expectEqualStrings("AND", toks[3].text);
}

test "lex path with index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lx = Lexer.init("tags[2].name");
    const toks = try lx.tokenize(arena.allocator());
    const kinds = [_]TokKind{ .ident, .lbracket, .number, .rbracket, .dot, .ident, .eof };
    try testing.expectEqual(kinds.len, toks.len);
    for (kinds, toks) |k, t| try testing.expectEqual(k, t.kind);
    try testing.expectEqualStrings("2", toks[2].text);
}

test "lex ne and ge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lx = Lexer.init("a <> b >= c");
    const toks = try lx.tokenize(arena.allocator());
    try testing.expectEqual(TokKind.ne, toks[1].kind);
    try testing.expectEqual(TokKind.ge, toks[3].kind);
}

test "lex rejects bare # and :" {
    var lx = Lexer.init("# ");
    try testing.expectError(error.InvalidToken, lx.next());
    var lx2 = Lexer.init("@");
    try testing.expectError(error.InvalidToken, lx2.next());
}
