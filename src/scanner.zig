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

pub const Token = union(enum) {
    value: []const u8,
    keyword: Keyword,

    pub fn toString(self: Token, buffer: []u8) []u8 {
        const typeStr, const valStr = switch (self) {
            .value => |v| .{ "value", v },
            .keyword => |kw| .{ "keyword", @tagName(kw) },
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
    const lexeme_value = switch (lexeme[0]) {
        '"', '\'' => |first| qtd: {
            const lastIdx = lexeme.len - 1;
            break :qtd if (first == lexeme[lastIdx])
                lexeme[1..lastIdx]
            else
                lexeme;
        },
        else => lexeme,
    };
    return Token{ .value = lexeme_value };
}

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
        const tokens = try scan("EXIT", test_allocator);
        defer tokens.deinit();
        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.EXIT, 0);
    }
    {
        const tokens = try scan("GET http://some_site.com", test_allocator);
        defer tokens.deinit();

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.GET, 0);
        try expectTokenToBeValueAt(tokens.items[1], "http://some_site.com", 4);
    }
    {
        const test_val = "http://some_site.com/space=in url";
        const tokens = try scan("PUT \"" ++ test_val ++ "\"", test_allocator);
        defer tokens.deinit();

        try expectTokenToBeKeywordAt(tokens.items[0], Keyword.PUT, 0);
        try expectTokenToBeValueAt(tokens.items[1], test_val, 4);
    }
}

test "scan ignores spaces" {
    var tokens = try scan("      ", test_allocator);
    try expect(tokens.items.len == 0);
    tokens.deinit();

    tokens = try scan("   DELETE     someURL  ", test_allocator);
    defer tokens.deinit();
    try expect(tokens.items.len == 2);
    try expect(tokens.items[0].pos == 3);
    try expect(tokens.items[1].pos == 14);
}

test "scan works with long strings" {
    const str = "This_is_a_very_long_string,_it_must_have_at_least_128_characters_in_my_opinions,_though_121_should_be_fine_too!JustMakeSureItIsVeryLong...";

    const tokens = try scan("CONNECT " ++ str, test_allocator);
    defer tokens.deinit();

    var buffer: [32]u8 = undefined;
    try expectStringStartsWith("value: This_is_a_very_long_strin", tokens.items[1].token.toString(&buffer));
}

test "scan can handle inner quotes" {
    const testStrs: []const []const u8 = &.{ "0'23'5", "'123'5", "0'234'" };
    for (testStrs) |testStr| {
        const tokens = try scan(testStr, test_allocator);
        defer tokens.deinit();

        try expectTokenToBeValueAt(tokens.items[0], testStr, 0);
    }
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
