const std = @import("std");

const strings = @import("strings.zig");
const String = strings.String;

pub const Keyword = enum(u8) {
    EXIT,
    PRINT,
    SET,
    // HTTP methods
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,
};

pub const Token = union(enum) {
    value: String,
    keyword: Keyword,
    variable: String,
    whitespace: usize,
    invalid: String,

    pub fn toString(self: Token, buffer: []u8) []u8 {
        var temp_buf: [16]u8 = undefined;

        const type_str = @tagName(self);
        const val_str = switch (self) {
            .keyword => |kw| @tagName(kw),
            .whitespace => |l| std.fmt.bufPrint(&temp_buf, "{}", .{l}) catch &temp_buf,
            inline else => |v| v,
        };

        const max_len = @max(buffer.len - type_str.len - 2, 0);
        const print_val = if (val_str.len <= max_len)
            val_str
        else
            val_str[0..max_len];
        return std.fmt.bufPrint(buffer, "{s}: {s}", .{ type_str, print_val }) catch buffer;
    }

    pub fn isKeyword(self: Token, keyword: Keyword) bool {
        return switch (self) {
            .keyword => self.keyword == keyword,
            else => false,
        };
    }
};

pub const TokenInfo = struct { token: Token, lexeme: String, pos: usize };
pub const TokenList = std.ArrayList(TokenInfo);

const InvalidType = enum {
    unclosed_variable,
    invalid_variable,
    empty_variable,
    unclosed_quote,
};

fn InvalidReason(comptime t: InvalidType) String {
    return comptime switch (t) {
        .unclosed_quote => "Unclosed qoute",
        .invalid_variable => "Invalid character in variable reference",
        .unclosed_variable => "Unclosed variable reference",
        .empty_variable => "Empty variable reference",
    };
}

pub fn scan(line: String, allocator: std.mem.Allocator) !TokenList {
    var tokenList = TokenList.init(allocator);

    var scanner = Scanner{ .line = line };
    while (scanner.scanNextToken()) |token| {
        try tokenList.append(token);
        switch (token.token) {
            .invalid => break,
            else => {},
        }
    }

    return tokenList;
}

const Scanner = struct {
    line: String,

    idx: usize = 0,
    start: usize = 0,

    fn done(self: *Scanner) bool {
        return self.idx == self.line.len;
    }

    fn advance(self: *Scanner) void {
        if (!self.done()) self.idx += 1;
    }

    fn current(self: *Scanner) u8 {
        return if (!self.done()) self.line[self.idx] else 0;
    }

    fn lexeme(self: *Scanner) String {
        return self.line[self.start..self.idx];
    }

    fn scanNextToken(self: *Scanner) ?TokenInfo {
        self.start = self.idx;
        while (self.current() == ' ' and !self.done()) {
            self.advance();
        }
        if (self.done() or self.current() == '#') {
            return null;
        }
        if (self.start > 0 and self.start < self.idx) {
            return self.genTokenInfo(Token{ .whitespace = self.idx - self.start });
        }
        self.start = self.idx;

        return switch (self.current()) {
            '#' => null,
            '{' => if (self.scanVariable()) |v| v else self.scanAny(),
            '"', '\'' => |c| self.scanQuoted(c),
            else => self.scanAny(),
        };
    }

    fn scanVariable(self: *Scanner) ?TokenInfo {
        while (self.lexeme().len < 2 and !self.done()) {
            self.advance();
        }
        self.skipSpaces();

        if (!strings.startsWith(self.lexeme(), "{{")) {
            return null;
        }

        while (!strings.endsWith(self.lexeme(), "}}") and !self.done()) {
            if (self.current() == ' ') {
                self.skipSpaces();
                if (self.current() != '}') {
                    return self.invalid(InvalidType.invalid_variable);
                }
            }

            const c = self.current();
            const valid_c = std.ascii.isAlphanumeric(c) or switch (c) {
                '}', '_', '-', '.' => true,
                else => false,
            };
            if (!valid_c)
                return self.invalid(InvalidType.invalid_variable);

            self.advance();
        }

        if (strings.endsWith(self.lexeme(), "}}")) {
            const var_name = strings.trimWhitespace(self.trimLexeme(2));
            if (var_name.len == 0) {
                return self.invalid(InvalidType.empty_variable);
            }
            return self.genTokenInfo(Token{ .variable = var_name });
        }
        return self.invalid(InvalidType.unclosed_variable);
    }

    fn skipSpaces(self: *Scanner) void {
        while (!self.done() and self.current() == ' ') {
            self.advance();
        }
    }

    fn scanAny(self: *Scanner) TokenInfo {
        while (!self.done()) {
            self.advance();
            switch (self.current()) {
                ' ', '#' => break,
                '"', '\'', '{' => return self.genTokenInfo(Token{ .value = self.lexeme() }),
                else => {},
            }
        }
        return self.keywordOrChars();
    }

    fn scanQuoted(self: *Scanner, quote: u8) TokenInfo {
        self.advance();
        while (self.current() != quote and !self.done()) {
            self.advance();
        }

        if (self.current() == quote) {
            self.advance();
            return self.genTokenInfo(Token{ .value = self.trimLexeme(1) });
        } else {
            return self.invalid(InvalidType.unclosed_quote);
        }
    }

    fn trimLexeme(self: *Scanner, i: usize) String {
        return self.line[self.start + i .. self.idx - i];
    }

    fn keywordOrChars(self: *Scanner) TokenInfo {
        const token = if (std.meta.stringToEnum(Keyword, self.lexeme())) |k|
            Token{ .keyword = k }
        else
            Token{ .value = self.lexeme() };
        return self.genTokenInfo(token);
    }

    fn invalid(self: *Scanner, comptime t: InvalidType) TokenInfo {
        return self.genTokenInfo(.{ .invalid = InvalidReason(t) });
    }

    fn genTokenInfo(self: *Scanner, token: Token) TokenInfo {
        return TokenInfo{ .lexeme = self.lexeme(), .pos = self.start, .token = token };
    }
};

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectStringStartsWith = std.testing.expectStringStartsWith;
const test_allocator = std.testing.allocator;

test "token.toString should work for large value" {
    const str = "This_is_a_very_long_string,_it_must_have_at_least_128_characters_in_my_opinions,_though_121_should_be_fine_too!JustMakeSureItIsVeryLong...";

    var buffer: [32]u8 = undefined;
    const testTokenType = Token{ .value = str };
    try expectStringStartsWith("value: This_is_a_very_long_strin", testTokenType.toString(&buffer));
}

fn expectTokenToBeKeywordAt(token: TokenInfo, kw: Keyword, position: usize) !void {
    switch (token.token) {
        .keyword => |actual_kw| {
            try expect(actual_kw == kw);
            try expectEqualStrings(token.lexeme, @tagName(kw));
            try expect(token.pos == position);
        },
        else => try expect(false),
    }
}

fn expectTokenToBeValueAt(token: TokenInfo, value: String, position: usize) !void {
    switch (token.token) {
        .value => |val| {
            try expectEqualStrings(value, val);

            const indexOf = std.mem.indexOf(u8, token.lexeme, value);
            if (indexOf) |i|
                try expect(i == 0 or i == 1)
            else
                try expect(false);
            if (token.pos != position) {
                std.log.err("Expected position {}, but got {}\n", .{ position, token.pos });
                try expect(false);
            }
        },
        else => {
            var str_buf: [1024]u8 = undefined;
            std.log.err(
                "Expected value, but got {s} for lexeme \"{s}\"\n",
                .{ token.token.toString(&str_buf), token.lexeme },
            );
            try expect(false);
        },
    }
}

fn expectTokenToBeVarAt(token: TokenInfo, value: String, position: usize) !void {
    switch (token.token) {
        .variable => |val| {
            try expectEqualStrings(value, val);

            const indexOf = std.mem.indexOf(u8, token.lexeme, value);
            if (indexOf) |i| try expect(i > 1) else try expect(false);

            if (token.pos != position) {
                std.log.err("Expected position {}, but got {}\n", .{ position, token.pos });
                try expect(false);
            }
        },
        else => {
            var str_buf: [1024]u8 = undefined;
            std.log.err(
                "Expected variable, but got {s} for lexeme \"{s}\"\n",
                .{ token.token.toString(&str_buf), token.lexeme },
            );
            try expect(false);
        },
    }
}

test scan {
    {
        const tokens = try scan("EXIT", test_allocator);
        defer tokens.deinit();
        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.EXIT, 0);
        try expect(tokens.items.len == 1);
    }
    {
        const tokens = try scan("SET some_variable some_value", test_allocator);
        defer tokens.deinit();

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.SET, 0);
        try expectTokenToBeValueAt(tokens.items[2], "some_variable", 4);
        try expectTokenToBeValueAt(tokens.items[4], "some_value", 18);
        try expect(tokens.items.len == 5);
    }
    {
        const test_val = "http://some_site.com/space=in url";
        const tokens = try scan("PUT \"" ++ test_val ++ "\"", test_allocator);
        defer tokens.deinit();

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.PUT, 0);
        try expectTokenToBeValueAt(tokens.items[2], test_val, 4);
        try expect(tokens.items.len == 3);
    }
    {
        const tokens = try scan("PRINT {{ some.variable }}", test_allocator);
        defer tokens.deinit();

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.PRINT, 0);
        try expectTokenToBeVarAt(tokens.items[2], "some.variable", 6);
        try expect(tokens.items.len == 3);
    }
}

test "scan ignores spaces" {
    var tokens = try scan("      ", test_allocator);
    try expect(tokens.items.len == 0);
    tokens.deinit();

    tokens = try scan("   DELETE     someURL  ", test_allocator);
    defer tokens.deinit();
    try expect(tokens.items.len == 3);
    try expect(tokens.items[0].pos == 3);
    try expect(tokens.items[2].pos == 14);
}

test "scan works with long strings" {
    const str = "This_is_a_very_long_string,_it_must_have_at_least_128_characters_in_my_opinions,_though_121_should_be_fine_too!JustMakeSureItIsVeryLong...";

    const tokens = try scan("CONNECT " ++ str, test_allocator);
    defer tokens.deinit();

    var buffer: [32]u8 = undefined;
    try expectStringStartsWith("value: This_is_a_very_long_strin", tokens.items[2].token.toString(&buffer));
}

test "scan stops at comment" {
    const TestCase = struct {
        tst: String,
        exp: usize,
    };

    const tests = [_]TestCase{
        TestCase{ .tst = "# comment only", .exp = 0 },
        TestCase{ .tst = "#", .exp = 0 },
        TestCase{ .tst = "   #", .exp = 0 },
        TestCase{ .tst = " # spaced comment", .exp = 0 },
        TestCase{ .tst = "EXIT # we are done", .exp = 1 },
        TestCase{ .tst = "GET http://somesite.com # GET request ", .exp = 3 },
    };
    for (tests) |case| {
        const tokens = try scan(case.tst, test_allocator);
        defer tokens.deinit();

        if (tokens.items.len == case.exp) {
            try expect(true);
        } else {
            std.log.err(
                "Expect token length {} for {s}, but got {}\n",
                .{ case.exp, case.tst, tokens.items.len },
            );
            try expect(false);
        }
    }
}

test "scan correctly scans consecutive values" {
    const test_lines = &[_]String{
        "{{ some_var }}'some string'some_raw",
        "{{ some_var }}some_raw'some string",
        "'some string'some_raw{{ some_var }}",
        "'some_string'{{ some_var }}some_raw",
        "some-raw{{ some_var }}'some string'",
        "some-raw'some_string'{{ some_var }}",
    };

    inline for (test_lines) |line| {
        var tokens = try scan(line, test_allocator);
        defer tokens.clearAndFree();

        try expect(tokens.items.len == 3);
        inline for (0..2) |i| {
            const token = tokens.items[i];

            switch (token.token) {
                .value, .variable => |v| try expectStringStartsWith(v, "some"),
                else => {
                    var b: [256]u8 = undefined;
                    std.log.err(
                        "failure with {s}: got {s} at {}",
                        .{ line, token.token.toString(&b), i },
                    );
                    try expect(false);
                },
            }
        }
    }
}

test "Scanner.scanNextToken scans single token" {
    var scanner = Scanner{ .line = "hgl" };
    const token = scanner.scanNextToken();

    try expectTokenToBeValueAt(token.?, "hgl", 0);
}

test "Scanner.scanNextToken scans second token" {
    const test_str = "012 456 89";

    var scanner = Scanner{ .line = test_str, .idx = 4 };
    const token = scanner.scanNextToken();

    try expectTokenToBeValueAt(token.?, "456", 4);
}

test "Scanner.scanNextToken scans entire quote" {
    const test_str = "\"12 45\"";
    var scanner = Scanner{ .line = test_str };
    const token = scanner.scanNextToken();

    try expectTokenToBeValueAt(token.?, "12 45", 0);
}

test "Scanner.scanVariable scans variable" {
    const test_str = "{{ 12_45 }}";
    var scanner = Scanner{ .line = test_str };
    const token = scanner.scanVariable();

    try expectTokenToBeVarAt(token.?, "12_45", 0);
}

test "Scanner.scanVariable breaks when it should" {
    const test_strs = &[_]String{ "{{}}", "{{", "{{ kl{{ }}", "{{ }}", "{{ f f }}", "{{ f#f }}" };

    inline for (test_strs) |test_str| {
        var scanner = Scanner{ .line = test_str };
        const token = scanner.scanVariable();

        switch (token.?.token) {
            .invalid => try expect(true),
            else => {
                var buf: [128]u8 = undefined;
                std.log.err(
                    "Expected invalid token for {s}, but got {s}",
                    .{ test_str, token.?.token.toString(&buf) },
                );
                try expect(false);
            },
        }
    }
}

test "Scanner.scanQuoted scans inside quote" {
    const test_str = "'12 45'7";
    var scanner = Scanner{ .line = test_str };
    const token = scanner.scanQuoted(test_str[0]);

    try expectTokenToBeValueAt(token, "12 45", 0);
}
