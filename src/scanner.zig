const std = @import("std");
const Allocator = std.mem.Allocator;

const strings = @import("strings.zig");
const String = strings.String;

pub const Keyword = enum(u8) {
    EXIT,
    SET,
    PRINT,
    WAIT,
    ERROR,
    REQUEST,
    // Flow Control
    DO,
    UNTIL,
    WHILE,
    FOR,
    IF,
    ELSE,
    FUN,
    // HTTP methods
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,
    PATCH,
    // Asserts
    ASSERT,
    ASSERT_SUCCESS,
    ASSERT_REDIRECT,
    ASSERT_FAILED,
    ASSERT_RANGE,
    ASSERT_CODE,
    ASSERT_CONTAINS,
    ASSERT_ERROR,
    // File Ops
    SCRIPT,
    IMPORT,
    EXPORT,
    APPEND,
    REPORT,
};

pub const Token = union(enum) {
    keyword: Keyword,
    literal: String,
    quoted: String,
    identifiers: []const String,
    operator: u8,

    whitespace: usize,
    expression: bool,
    subroutine: bool,

    invalid: String,

    pub fn isKeyword(self: Token, keyword: Keyword) bool {
        return switch (self) {
            .keyword => self.keyword == keyword,
            else => false,
        };
    }
};

pub const TokenInfo = struct {
    token: Token,
    lexeme: String,
    pos: usize,
    line: usize,
    allocator: Allocator,

    pub fn deinit(self: *TokenInfo) void {
        switch (self.token) {
            .identifiers => |i| self.allocator.free(i),
            else => {},
        }
        self.allocator.free(self.lexeme);
    }
};

pub const TokenList = std.ArrayList(TokenInfo);

pub fn deinitTokenList(token_list: *TokenList) void {
    for (token_list.items) |*i| {
        i.deinit();
    }
    token_list.deinit();
}

const InvalidType = enum {
    empty_expression,
    invalid_expression,
    unexpected_expression_close,
    unclosed_quote,
};

fn InvalidReason(comptime t: InvalidType) String {
    return comptime switch (t) {
        .empty_expression => "Empty Expression",
        .invalid_expression => "Invalid Character in Expression",
        .unexpected_expression_close => "Closed Expression Without Opening",
        .unclosed_quote => "Unclosed Quote",
    };
}

pub const operators = "+-/*%=!|&^";

var scanner: Scanner = Scanner{};

pub fn scan(line: String, allocator: Allocator) !TokenList {
    var token_list = TokenList.init(allocator);
    try continueScan(line, &token_list);
    return token_list;
}

pub fn continueScan(line: String, token_list: *TokenList) !void {
    scanner.newLine(line);
    while (try scanner.scanNextToken(test_allocator)) |token| {
        try token_list.append(token);
        switch (token.token) {
            .invalid => break,
            else => {},
        }
    }
}

const Scanner = struct {
    line: String = "",

    line_number: usize = 0,
    idx: usize = 0,
    start: usize = 0,
    expression_level: usize = 0,

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

    fn newLine(self: *Scanner, line: String) void {
        self.line_number += 1;
        self.start = 0;
        self.idx = 0;
        self.line = line;
    }
    fn reset(self: *Scanner) void {
        self.line = "";
        self.line_number = 0;
        self.idx = 0;
        self.start = 0;
        self.expression_level = 0;
    }

    fn scanNextToken(self: *Scanner, allocator: Allocator) !?TokenInfo {
        self.start = self.idx;
        self.skipSpaces();
        if (self.done() or self.current() == '#') {
            return null;
        }
        if (self.start > 0 and self.start < self.idx and self.expression_level == 0) {
            return try self.genTokenInfo(Token{ .whitespace = self.idx - self.start }, allocator);
        }
        self.start = self.idx;

        return switch (self.current()) {
            '#' => null,
            '(', ')', '{', '}' => try self.scanSingle(allocator),
            '"', '\'' => |c| try self.scanQuoted(c, allocator),
            else => if (self.expression_level == 0) try self.scanWord(allocator) else try self.scanExpression(allocator),
        };
    }

    fn scanSingle(self: *Scanner, allocator: Allocator) !TokenInfo {
        const c = self.current();
        self.advance();
        switch (c) {
            '(' => {
                self.expression_level += 1;
                return try self.genTokenInfo(.{ .expression = true }, allocator);
            },
            ')' => {
                if (self.expression_level == 0)
                    return try self.invalid(InvalidType.unexpected_expression_close, allocator);

                self.expression_level -= 1;
                return try self.genTokenInfo(.{ .expression = false }, allocator);
            },
            '{' => return try self.genTokenInfo(.{ .subroutine = true }, allocator),
            '}' => return try self.genTokenInfo(.{ .subroutine = false }, allocator),
            else => std.debug.panic("Expected '{{', '}}', '(', or ')', but got '{c}'", .{c}),
        }
    }

    fn skipSpaces(self: *Scanner) void {
        while (!self.done() and (self.current() == ' ' or self.current() == '\t')) {
            self.advance();
        }
    }

    fn scanQuoted(self: *Scanner, quote: u8, allocator: Allocator) !TokenInfo {
        self.advance();
        while (self.current() != quote and !self.done()) {
            self.advance();
        }

        if (self.current() == quote) {
            self.advance();
            const value = self.line[self.start + 1 .. self.idx - 1];
            const owned_lexeme = try strings.toOwned(self.lexeme(), allocator);
            return try self.genTokenInfoOwned(Token{ .quoted = value }, owned_lexeme, allocator);
        } else {
            return try self.invalid(InvalidType.unclosed_quote, allocator);
        }
    }

    fn scanExpression(self: *Scanner, allocator: Allocator) !?TokenInfo {
        self.skipSpaces();
        const c = self.current();
        if (c == ')') return try self.invalid(InvalidType.empty_expression, allocator);
        if (c == '(') return try self.scanSingle(allocator);
        if (std.mem.containsAtLeastScalar(u8, strings.alphanumeric ++ "_.", 1, c))
            return try self.scanIdentifiers(allocator);
        if (c == '\'' or c == '"') {
            const token = try self.scanQuoted(c, allocator);
            self.skipSpaces();
            return token;
        }
        if (std.mem.containsAtLeastScalar(u8, operators, 1, c)) {
            self.advance();
            return try self.genTokenInfo(.{ .operator = c }, allocator);
        }
        if (c == '#') {
            return null;
        }
        return try self.invalid(InvalidType.invalid_expression, allocator);
    }

    fn scanIdentifiers(self: *Scanner, allocator: Allocator) !TokenInfo {
        if (self.current() == '.') {
            self.advance();
        }
        var parts: usize = 1;

        const valid_chars = strings.alphanumeric ++ "_.-";
        while (std.mem.containsAtLeastScalar(u8, valid_chars, 1, self.current())) {
            self.advance();
            if (self.current() == '.') {
                parts += 1;
            }
        }

        const owned_lexeme = try strings.toOwned(self.lexeme(), allocator);

        var start: usize = 0;
        var end: usize = self.lexeme().len;
        if (self.lexeme()[start] == '.') start += 1;
        if (self.lexeme()[end - 1] == '.') {
            end -= 1;
            parts -= 1;
        }

        const identifiers = try if (strings.eql(owned_lexeme, "."))
            splitIdentifiers("", 0, allocator)
        else if (strings.eql(owned_lexeme, ".."))
            splitIdentifiers(owned_lexeme[1..], 1, allocator)
        else
            splitIdentifiers(owned_lexeme[start..end], parts, allocator);

        const token = self.genTokenInfoOwned(.{ .identifiers = identifiers }, owned_lexeme, allocator);
        self.skipSpaces();
        return token;
    }

    fn splitIdentifiers(value: String, size: usize, allocator: Allocator) ![]String {
        var identifiers = try std.ArrayList(String).initCapacity(allocator, size);
        var spliterator = std.mem.splitScalar(u8, value, '.');
        while (spliterator.next()) |identifier| {
            identifiers.appendAssumeCapacity(identifier);
        }
        return try identifiers.toOwnedSlice();
    }

    fn scanWord(self: *Scanner, allocator: Allocator) !TokenInfo {
        while (!self.done()) {
            self.advance();
            switch (self.current()) {
                ' ',
                '#',
                '"',
                '\'',
                '{',
                '}',
                '(',
                ')',
                => break,
                else => {},
            }
        }
        const owned_lexeme = try strings.toOwned(self.lexeme(), allocator);
        const token = if (std.meta.stringToEnum(Keyword, self.lexeme())) |k|
            Token{ .keyword = k }
        else
            Token{ .literal = self.lexeme() };
        return try self.genTokenInfoOwned(token, owned_lexeme, allocator);
    }

    fn invalid(self: *Scanner, comptime t: InvalidType, allocator: Allocator) !TokenInfo {
        return self.genTokenInfo(.{ .invalid = InvalidReason(t) }, allocator);
    }

    fn genTokenInfo(self: *Scanner, token: Token, allocator: Allocator) !TokenInfo {
        return self.genTokenInfoOwned(token, try strings.toOwned(self.lexeme(), allocator), allocator);
    }

    fn genTokenInfoOwned(self: *Scanner, token: Token, owned_lexeme: String, allocator: Allocator) !TokenInfo {
        return TokenInfo{
            .token = token,
            .lexeme = owned_lexeme,
            .pos = self.start,
            .line = self.line_number,
            .allocator = allocator,
        };
    }
};

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectStringStartsWith = std.testing.expectStringStartsWith;
const test_allocator = std.testing.allocator;

fn expectPos(expected: usize, actual: usize) !void {
    if (expected != actual) {
        std.log.err("Expected position {}, but got {}\n", .{ expected, actual });
        try expect(false);
    }
}

fn expectTokenToBeKeywordAt(token: TokenInfo, kw: Keyword, position: usize) !void {
    switch (token.token) {
        .keyword => |actual_kw| {
            try expect(actual_kw == kw);
            try expectEqualStrings(token.lexeme, @tagName(kw));
            try expectPos(position, token.pos);
        },
        else => try expect(false),
    }
}

fn expectTokenToBeLiteralAt(token: TokenInfo, value: String, position: usize) !void {
    switch (token.token) {
        .literal => |val| {
            try expectEqualStrings(value, val);

            const indexOf = std.mem.indexOf(u8, token.lexeme, value);
            if (indexOf) |i|
                try expect(i == 0)
            else
                try expect(false);
            try expectPos(position, token.pos);
        },
        else => {
            std.log.err(
                "Expected value, but got {s} for lexeme \"{s}\"\n",
                .{ @tagName(token.token), token.lexeme },
            );
            try expect(false);
        },
    }
}

fn expectTokenToBeQuotedAt(token: TokenInfo, value: String, position: usize) !void {
    switch (token.token) {
        .quoted => |val| {
            try expectEqualStrings(value, val);

            const indexOf = std.mem.indexOf(u8, token.lexeme, value);
            if (indexOf) |i|
                try expect(i == 1)
            else
                try expect(false);
            try expectPos(position, token.pos);
        },
        else => {
            std.log.err(
                "Expected value, but got {s} for lexeme \"{s}\"\n",
                .{ @tagName(token.token), token.lexeme },
            );
            try expect(false);
        },
    }
}

fn expectTokenToBeIdAt(token: TokenInfo, value: []const String, position: usize) !void {
    switch (token.token) {
        .identifiers => |val| {
            try expect(value.len == val.len);
            for (value, val) |exp, got| {
                try expectEqualStrings(exp, got);
            }
            try expectPos(position, token.pos);
        },
        else => {
            std.log.err(
                "Expected variable, but got {s} for lexeme \"{s}\"\n",
                .{ @tagName(token.token), token.lexeme },
            );
            try expect(false);
        },
    }
}

fn expectTokenToBeOpAt(token: TokenInfo, value: u8, position: usize) !void {
    switch (token.token) {
        .operator => |val| {
            try expect(val == value);
            try expectPos(position, token.pos);
        },
        else => {
            std.log.err(
                "Expected operator, but got {s} for lexeme \"{s}\"\n",
                .{ @tagName(token.token), token.lexeme },
            );
            try expect(false);
        },
    }
}

fn expectTokenToBeBracketAt(actual: TokenInfo, expected: Token, position: usize) !void {
    switch (actual.token) {
        .expression => if (expected != .expression) {
            std.log.err(
                "Expected {s}, but got expression for lexeme \"{s}\"\n",
                .{ @tagName(actual.token), actual.lexeme },
            );
            try expect(false);
        },
        .subroutine => if (expected != .subroutine) {
            std.log.err(
                "Expected {s}, but got subrotine for lexeme \"{s}\"\n",
                .{ @tagName(actual.token), actual.lexeme },
            );
            try expect(false);
        },
        else => {
            std.log.err(
                "Expected expression or subroutine, but got {s} for lexeme \"{s}\"\n",
                .{ @tagName(actual.token), actual.lexeme },
            );
            try expect(false);
        },
    }

    const expect_open = switch (expected) {
        .expression, .subroutine => |v| v,
        else => unreachable,
    };
    const got_open = switch (actual.token) {
        .expression, .subroutine => |v| v,
        else => unreachable,
    };
    try expect(expect_open == got_open);

    try expectPos(position, actual.pos);
}

test scan {
    {
        var tokens = try scan("EXIT", test_allocator);
        defer deinitTokenList(&tokens);
        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.EXIT, 0);
        try expect(tokens.items.len == 1);
    }
    {
        var tokens = try scan("SET some_variable some_value", test_allocator);
        defer deinitTokenList(&tokens);

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.SET, 0);
        try expectTokenToBeLiteralAt(tokens.items[2], "some_variable", 4);
        try expectTokenToBeLiteralAt(tokens.items[4], "some_value", 18);
        try expect(tokens.items.len == 5);
    }
    {
        const test_val = "http://some_site.com/space=in url";
        var tokens = try scan("PUT \"" ++ test_val ++ "\"", test_allocator);
        defer deinitTokenList(&tokens);

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.PUT, 0);
        try expectTokenToBeQuotedAt(tokens.items[2], test_val, 4);
        try expect(tokens.items.len == 3);
    }
    {
        var tokens = try scan("PRINT (some.variable)", test_allocator);
        defer deinitTokenList(&tokens);

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.PRINT, 0);
        try expectTokenToBeIdAt(tokens.items[3], &[_]String{ "some", "variable" }, 7);
        try expect(tokens.items.len == 5);
    }
    {
        var tokens = try scan("DO context FUN some_function (some.variable) (another.variable)", test_allocator);
        defer deinitTokenList(&tokens);

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.DO, 0);
        try expectTokenToBeLiteralAt(tokens.items[2], "context", 3);
        try expectTokenToBeKeywordAt(tokens.items[4], Keyword.FUN, 11);
        try expectTokenToBeLiteralAt(tokens.items[6], "some_function", 15);
        try expectTokenToBeIdAt(tokens.items[9], &[_]String{ "some", "variable" }, 30);
        try expectTokenToBeIdAt(tokens.items[13], &[_]String{ "another", "variable" }, 46);
        try expect(tokens.items.len == 15);
    }
    {
        var tokens = try scan("WAIT 1", test_allocator);
        defer deinitTokenList(&tokens);

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.WAIT, 0);
        try expectTokenToBeLiteralAt(tokens.items[2], "1", 5);
        try expect(tokens.items.len == 3);
    }
    {
        var tokens = try scan("ERROR some_error", test_allocator);
        defer deinitTokenList(&tokens);

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.ERROR, 0);
        try expectTokenToBeLiteralAt(tokens.items[2], "some_error", 6);
        try expect(tokens.items.len == 3);
    }
    {
        var tokens = try scan("ASSERT true", test_allocator);
        defer deinitTokenList(&tokens);

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.ASSERT, 0);
        try expectTokenToBeLiteralAt(tokens.items[2], "true", 7);
        try expect(tokens.items.len == 3);
    }
}

test continueScan {
    {
        const lines = &[_]String{
            "(",
            "\"multiline\" +",
            "\"expression\"",
            ")",
        };
        var tokens = TokenList.init(test_allocator);
        defer deinitTokenList(&tokens);

        for (lines) |line| {
            try continueScan(line, &tokens);
        }

        try expectTokenToBeBracketAt(tokens.items[0], .{ .expression = true }, 0);
        try expectTokenToBeQuotedAt(tokens.items[1], "multiline", 0);
        try expectTokenToBeOpAt(tokens.items[2], '+', 12);
        try expectTokenToBeQuotedAt(tokens.items[3], "expression", 0);
        try expectTokenToBeBracketAt(tokens.items[4], .{ .expression = false }, 0);
        try expect(tokens.items.len == 5);
    }
    {
        const lines = &[_]String{
            "DO context IF(var1 = 0) {",
            "\t# Valid script",
            "} ELSE IF(var2 = 4) {",
            "\t# Valid script",
            "} ELSE {",
            "\t# Valid script",
            "}",
        };
        var tokens = TokenList.init(test_allocator);
        defer deinitTokenList(&tokens);

        for (lines) |line| {
            try continueScan(line, &tokens);
        }

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.DO, 0);
        try expectTokenToBeLiteralAt(tokens.items[2], "context", 3);
        try expectTokenToBeKeywordAt(tokens.items[4], Keyword.IF, 11);
        try expectTokenToBeBracketAt(tokens.items[5], .{ .expression = true }, 13);
        try expectTokenToBeIdAt(tokens.items[6], &[_]String{"var1"}, 14);
        try expectTokenToBeOpAt(tokens.items[7], '=', 19);
        try expectTokenToBeBracketAt(tokens.items[9], .{ .expression = false }, 22);
        try expectTokenToBeBracketAt(tokens.items[11], .{ .subroutine = true }, 24);
        try expectTokenToBeBracketAt(tokens.items[12], .{ .subroutine = false }, 0);
        try expectTokenToBeKeywordAt(tokens.items[14], Keyword.ELSE, 2);
        try expectTokenToBeKeywordAt(tokens.items[16], Keyword.IF, 7);
        try expectTokenToBeBracketAt(tokens.items[23], .{ .subroutine = true }, 20);
        try expectTokenToBeBracketAt(tokens.items[24], .{ .subroutine = false }, 0);
        try expectTokenToBeKeywordAt(tokens.items[26], Keyword.ELSE, 2);
        try expectTokenToBeBracketAt(tokens.items[28], .{ .subroutine = true }, 7);
        try expectTokenToBeBracketAt(tokens.items[29], .{ .subroutine = false }, 0);
        try expect(tokens.items.len == 30);
    }
    {
        const lines = &[_]String{
            "FUN name arg_name {",
            "\t# Valid script",
            "\tPRINT (name)",
            "\tPRINT (arg_name)",
            "\tPRINT (args.1)",
            "}",
        };
        var tokens = TokenList.init(test_allocator);
        defer deinitTokenList(&tokens);

        for (lines) |line| {
            try continueScan(line, &tokens);
        }

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.FUN, 0);
        try expectTokenToBeLiteralAt(tokens.items[2], "name", 4);
        try expectTokenToBeLiteralAt(tokens.items[4], "arg_name", 9);
        try expectTokenToBeBracketAt(tokens.items[6], .{ .subroutine = true }, 18);
        try expectTokenToBeKeywordAt(tokens.items[7], Keyword.PRINT, 1);
        try expectTokenToBeKeywordAt(tokens.items[12], Keyword.PRINT, 1);
        try expectTokenToBeKeywordAt(tokens.items[17], Keyword.PRINT, 1);
        try expectTokenToBeBracketAt(tokens.items[22], .{ .subroutine = false }, 0);
        try expect(tokens.items.len == 23);
    }
}

test "scan ignores spaces" {
    var tokens = try scan("      ", test_allocator);
    try expect(tokens.items.len == 0);
    deinitTokenList(&tokens);

    tokens = try scan("   DELETE     someURL  ", test_allocator);
    defer deinitTokenList(&tokens);
    try expect(tokens.items.len == 3);
    try expect(tokens.items[0].pos == 3);
    try expect(tokens.items[2].pos == 14);
}

test "scan works with long strings" {
    const str = "This_is_a_very_long_string,_it_must_have_at_least_128_characters_in_my_opinions,_though_121_should_be_fine_too!JustMakeSureItIsVeryLong...";

    var tokens = try scan("CONNECT " ++ str, test_allocator);
    defer deinitTokenList(&tokens);

    try expectStringStartsWith(tokens.items[2].token.literal, "This_is_a_very_long_strin");
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
        TestCase{ .tst = "#GET http://somesite.com", .exp = 0 },
    };
    for (tests) |case| {
        var tokens = try scan(case.tst, test_allocator);
        defer deinitTokenList(&tokens);

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

test "scan correctly scans values" {
    const cases = &[_]struct { tst: String, exp: []const Token }{
        .{ .tst = "value", .exp = &[_]Token{.{ .literal = "value" }} },
        .{ .tst = "\"string value\"", .exp = &[_]Token{.{ .quoted = "string value" }} },
        .{ .tst = "(expression)", .exp = &[_]Token{
            .{ .expression = true },
            .{ .identifiers = &[_]String{"expression"} },
            .{ .expression = false },
        } },
        .{ .tst = "('string in expression')", .exp = &[_]Token{
            .{ .expression = true },
            .{ .quoted = "string in expression" },
            .{ .expression = false },
        } },
        .{ .tst = "('multiline'", .exp = &[_]Token{
            .{ .expression = true },
            .{ .quoted = "multiline" },
        } },
        .{ .tst = "(multiline  # Some comment", .exp = &[_]Token{
            .{ .expression = true },
            .{ .identifiers = &[_]String{"multiline"} },
        } },
        .{ .tst = "(\"nested\" + (expression))", .exp = &[_]Token{
            .{ .expression = true },
            .{ .quoted = "nested" },
            .{ .operator = '+' },
            .{ .expression = true },
            .{ .identifiers = &[_]String{"expression"} },
            .{ .expression = false },
            .{ .expression = false },
        } },
        .{ .tst = "list._LEN 3.6", .exp = &[_]Token{
            .{ .literal = "list._LEN" },
            .{ .whitespace = 1 },
            .{ .literal = "3.6" },
        } },
    };

    inline for (cases) |case| {
        scanner.reset();
        var tokens = try scan(case.tst, test_allocator);
        defer deinitTokenList(&tokens);

        if (tokens.items.len == case.exp.len) {
            try expect(true);
        } else {
            std.log.err(
                "Expect token length {} for {s}, but got {}:\n{any}",
                .{ case.exp.len, case.tst, tokens.items.len, tokens.items },
            );
            try expect(false);
        }

        for (case.exp, tokens.items) |exp_token, got_token| {
            switch (exp_token) {
                .literal => |l| {
                    try expect(got_token.token == .literal);
                    try expectEqualStrings(l, got_token.token.literal);
                },
                .quoted => |q| {
                    try expect(got_token.token == .quoted);
                    try expectEqualStrings(q, got_token.token.quoted);
                },
                .expression => |e| {
                    try expect(got_token.token == .expression);
                    try expect(got_token.token.expression == e);
                },
                .identifiers => |i| {
                    try expectTokenToBeIdAt(got_token, i, got_token.pos);
                },
                .operator => |o| {
                    try expect(got_token.token == .operator);
                    try expect(got_token.token.operator == o);
                },
                .whitespace => |w| {
                    try expect(got_token.token == .whitespace);
                    try expect(got_token.token.whitespace == w);
                },
                else => try expect(false),
            }
        }
    }
}

test "scan correctly scans consecutive values" {
    const test_lines = &[_]String{
        "( some_var )'some string'some_raw",
        "( some_var )some_raw'some string'",
        "'some string'some_raw( some_var )",
        "'some_string'( some_var )some_raw",
        "some-raw( some_var )'some string'",
        "some-raw'some_string'( some_var )",
    };

    inline for (test_lines) |line| {
        var tokens = try scan(line, test_allocator);
        defer deinitTokenList(&tokens);

        if (tokens.items.len != 5) {
            std.log.err(
                "Expected 5 tokens for {s}, but got {}:\n{any}\n",
                .{ line, tokens.items.len, tokens.items },
            );
            try expect(false);
        }

        for (tokens.items) |token| {
            switch (token.token) {
                .literal, .quoted => |v| try expectStringStartsWith(v, "some"),
                .identifiers => |i| try expectStringStartsWith(i[0], "some"),
                .expression => {},
                else => {
                    std.log.err(
                        "failure with {s}: got {s} at {}",
                        .{ line, @tagName(token.token), token.pos },
                    );
                    try expect(false);
                },
            }
        }
    }
}

test "scan correctly scans asserts" {
    const cases = &[_]struct { tst: String, kw: Keyword, args: []const String }{
        .{ .tst = "ASSERT value", .kw = Keyword.ASSERT, .args = &[_]String{"value"} },
        .{ .tst = "ASSERT_SUCCESS", .kw = Keyword.ASSERT_SUCCESS, .args = &[_]String{} },
        .{ .tst = "ASSERT_REDIRECT", .kw = Keyword.ASSERT_REDIRECT, .args = &[_]String{} },
        .{ .tst = "ASSERT_FAILED", .kw = Keyword.ASSERT_FAILED, .args = &[_]String{} },
        .{ .tst = "ASSERT_RANGE 200", .kw = Keyword.ASSERT_RANGE, .args = &[_]String{"200"} },
        .{ .tst = "ASSERT_CODE 419", .kw = Keyword.ASSERT_CODE, .args = &[_]String{"419"} },
        .{ .tst = "ASSERT_CONTAINS WhatHaveYou? Have", .kw = Keyword.ASSERT_CONTAINS, .args = &[_]String{ "WhatHaveYou?", "Have" } },
    };

    inline for (cases) |case| {
        var token_list = try scan(case.tst, test_allocator);
        defer deinitTokenList(&token_list);

        var tokens = token_list.items;
        try expect(tokens[0].token == .keyword);
        try expect(tokens[0].token.keyword == case.kw);

        try expect(tokens.len == case.args.len * 2 + 1);
        if (case.args.len == 0) continue;
        for (tokens[1..], 0..) |token, i| {
            if (i % 2 == 0) {
                try expect(token.token == .whitespace);
            } else {
                try expect(token.token == .literal);
                try expectEqualStrings(case.args[i / 2], token.token.literal);
            }
        }
    }
}

test "scan correctly scans file operations" {
    const cases = &[_]struct { tst: String, kw: Keyword, args: []const String }{
        .{ .tst = "SCRIPT file_name", .kw = Keyword.SCRIPT, .args = &[_]String{"file_name"} },
        .{ .tst = "IMPORT variable file_name", .kw = Keyword.IMPORT, .args = &[_]String{ "variable", "file_name" } },
        .{ .tst = "EXPORT variable file_name", .kw = Keyword.EXPORT, .args = &[_]String{ "variable", "file_name" } },
        .{ .tst = "APPEND variable file_name", .kw = Keyword.APPEND, .args = &[_]String{ "variable", "file_name" } },
        .{ .tst = "REPORT file_name", .kw = Keyword.REPORT, .args = &[_]String{"file_name"} },
    };

    inline for (cases) |case| {
        var token_list = try scan(case.tst, test_allocator);
        defer deinitTokenList(&token_list);

        var tokens = token_list.items;
        try expect(tokens[0].token == .keyword);
        try expect(tokens[0].token.keyword == case.kw);

        try expect(tokens.len == case.args.len * 2 + 1);
        if (case.args.len == 0) continue;
        for (tokens[1..], 0..) |token, i| {
            if (i % 2 == 0) {
                try expect(token.token == .whitespace);
            } else {
                try expect(token.token == .literal);
                try expectEqualStrings(case.args[i / 2], token.token.literal);
            }
        }
    }
}

test "Scanner.scanNextToken scans single token" {
    const test_str = "hgl";
    var test_scanner = Scanner{ .line = test_str };
    var token = try test_scanner.scanNextToken(test_allocator);
    defer token.?.deinit();

    try expectTokenToBeLiteralAt(token.?, "hgl", 0);
}

test "Scanner.scanNextToken scans second token" {
    const test_str = "012 456 89";

    var test_scanner = Scanner{ .line = test_str, .idx = 4 };
    var token = try test_scanner.scanNextToken(test_allocator);
    defer token.?.deinit();

    try expectTokenToBeLiteralAt(token.?, "456", 4);
}

test "Scanner.scanNextToken scans entire quote" {
    const test_str = "\"12 45\"";
    var test_scanner = Scanner{ .line = test_str };
    var token = try test_scanner.scanNextToken(test_allocator);
    defer token.?.deinit();

    try expectTokenToBeQuotedAt(token.?, "12 45", 0);
}

test "Scanner.scanNextToken scans expression" {
    const test_str = "(12a45)";
    var test_scanner = Scanner{ .line = test_str };
    var token = try test_scanner.scanNextToken(test_allocator);
    token.?.deinit();
    token = try test_scanner.scanNextToken(test_allocator);
    defer token.?.deinit();

    try expectTokenToBeIdAt(token.?, &[_]String{"12a45"}, 1);
}

test "Scanner.scanQuoted scans inside quote" {
    const test_str = "'12 45'7";
    var test_scanner = Scanner{ .line = test_str };
    var token = try test_scanner.scanQuoted(test_str[0], test_allocator);
    defer token.deinit();

    try expectTokenToBeQuotedAt(token, "12 45", 0);
}

test "Scanner.scanIdentifiers scans multiple identifiers" {
    const cases = &[_]struct { tst: String, expected: []const String }{};
    var test_scanner = Scanner{};

    inline for (cases) |case| {
        scanner.newLine(case.tst);
        var token = try try test_scanner.scanIdentifiers(test_allocator);
        defer token.deinit();

        try expect(token.token == .identifiers);
        try expect(case.expected.len == token.token.identifiers.len);
        for (case.expected, token.token.identifiers) |expected_id, got_id| {
            try expectEqualStrings(expected_id, got_id);
        }
    }
}
