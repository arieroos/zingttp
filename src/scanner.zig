const std = @import("std");

pub const Keyword = enum(u8) {
    EXIT,
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

pub const SyntaxError = union(enum) {
    UnclosedQuote: u8,

    pub fn toString(self: SyntaxError) []const u8 {
        return switch (self) {
            .UnclosedQuote => |q| "Unclosed Quote: " ++ .{q},
        };
    }
};

pub const Token = union(enum) {
    value: []const u8,
    keyword: Keyword,
    invalid: SyntaxError,

    pub fn toString(self: Token, buffer: []u8) []u8 {
        const typeStr, const valStr = switch (self) {
            .value => |v| .{ "value", v },
            .keyword => |kw| .{ "keyword", @tagName(kw) },
            .invalid => |inv| .{ "invalid", inv.toString() },
        };

        const maxValLen = @max(buffer.len - typeStr.len - 2, 0);
        const printVal = if (valStr.len <= maxValLen)
            valStr
        else
            valStr[0..maxValLen];
        return std.fmt.bufPrint(buffer, "{s}: {s}", .{ typeStr, printVal }) catch buffer;
    }

    pub fn isKeyword(self: Token, keyword: Keyword) bool {
        return switch (self) {
            .keyword => self.keyword == keyword,
            else => false,
        };
    }
};

pub const TokenInfo = struct { token: Token, lexeme: []const u8, pos: usize };
pub const TokenList = std.ArrayList(TokenInfo);

pub fn scan(line: []const u8, allocator: std.mem.Allocator) !TokenList {
    var start: usize = 0;

    var tokenList = TokenList.init(allocator);

    while (start < line.len) {
        const end = scanNextToken(line, start);

        if (end > start) {
            const lexeme = line[start..end];
            const tokenType =
                if (std.meta.stringToEnum(Keyword, lexeme)) |keyword|
                    Token{ .keyword = keyword }
                else
                    getValueToken(lexeme);

            try tokenList.append(TokenInfo{ .token = tokenType, .lexeme = lexeme, .pos = start });
        }

        start = end + 1;
    }

    return tokenList;
}

fn scanNextToken(line: []const u8, start: usize) usize {
    var current = start;

    while (current < line.len) {
        const c = line[current];
        switch (c) {
            ' ' => break,
            '"', '\'' => current = scanQuoted(line, current + 1, c),
            else => current += 1,
        }
    }
    return current;
}

fn scanQuoted(line: []const u8, start: usize, quote: u8) usize {
    var idx = start;
    while (idx < line.len and line[idx] != quote) {
        idx += 1;
    }
    return idx;
}

fn getValueToken(lexeme: []const u8) Token {
    const first = lexeme[0];
    const last = lexeme[lexeme.len - 1];
    const lexeme_value = switch (first) {
        '"', '\'' => if (first == last) lexeme[1 .. lexeme.len - 1] else {
            return Token{ .invalid = .{ .UnclosedQuote = first } };
        },
        else => lexeme,
    };
    return Token{ .value = lexeme_value };
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const testAllocator = std.testing.allocator;

test "token.toString should work for large value" {
    const str = "This_is_a_very_long_string,_it_must_have_at_least_128_characters_in_my_opinions,_though_121_should_be_fine_too!JustMakeSureItIsVeryLong...";

    var buffer: [32]u8 = undefined;
    const testTokenType = Token{ .value = str };
    try expect(std.mem.startsWith(u8, testTokenType.toString(&buffer), "value: This_is_a_very_long_strin"));
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

fn expectTokenToBeValueAt(token: TokenInfo, value: []const u8, position: usize) !void {
    switch (token.token) {
        .value => |val| {
            try expectEqualStrings(value, val);

            const indexOf = std.mem.indexOf(u8, token.lexeme, value);
            if (indexOf) |i|
                try expect(i == 0 or i == 1)
            else
                try expect(false);
            try expect(token.pos == position);
        },
        else => try expect(false),
    }
}

test scan {
    {
        const exitToken = try scan("EXIT", testAllocator);
        defer exitToken.deinit();
        try expectTokenToBeKeywordAt(exitToken.items[0], Keyword.EXIT, 0);
    }
    {
        const getTokens = try scan("GET http://some_site.com", testAllocator);
        defer getTokens.deinit();

        try expectTokenToBeKeywordAt(getTokens.items[0], Keyword.GET, 0);
        try expectTokenToBeValueAt(getTokens.items[1], "http://some_site.com", 4);
    }
    {
        const tokens = try scan("PUT \"not a real site\"", testAllocator);
        defer tokens.deinit();

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.PUT, 0);
        try expectTokenToBeValueAt(tokens.items[1], "not a real site", 4);
    }
}

test "scan ignores spaces" {
    var tokens = try scan("      ", testAllocator);
    try expect(tokens.items.len == 0);
    tokens.deinit();

    tokens = try scan("   DELETE     someURL  ", testAllocator);
    defer tokens.deinit();
    try expect(tokens.items.len == 2);
    try expect(tokens.items[0].pos == 3);
    try expect(tokens.items[1].pos == 14);
}

test "scan works with long strings" {
    const str = "This_is_a_very_long_string,_it_must_have_at_least_128_characters_in_my_opinions,_though_121_should_be_fine_too!JustMakeSureItIsVeryLong...";

    var copy: [256]u8 = undefined;
    const tokens = try scan(try std.fmt.bufPrint(&copy, "CONNECT {s}", .{str}), testAllocator);
    defer tokens.deinit();

    var buffer: [32]u8 = undefined;
    try expect(std.mem.startsWith(u8, tokens.items[1].token.toString(&buffer), "value: This_is_a_very_long_strin"));
}

test "scanNextToken scans single token" {
    const end = scanNextToken("hgl", 0);
    try expect(end == 3);
}

test "scanNextToken scans second token" {
    const testStr = "012 456 89";
    const end = scanNextToken(testStr, 4);

    try expectEqualStrings("456", testStr[4..end]);
    try expect(end == 7);
}

test "scanNextToken scans entire quote" {
    const testStr = "\"12 45\"";
    const end = scanNextToken(testStr, 0);

    try expectEqualStrings(testStr[0..end], testStr);
}

test "scanQuoted scans inside quote" {
    const testStr = "'12 45'7";
    const end = scanQuoted(testStr, 1, '\'');

    try expectEqualStrings("12 45", testStr[1..end]);
    try expect(end == 6);
}

test "getValueToken returns error on unclosed quote" {
    const testStr = "'12 45 7";
    const token = getValueToken(testStr);

    switch (token) {
        .invalid => |i| try expectEqualStrings("Unclosed Quote: '", i.toString()),
        else => try expect(false),
    }
}
