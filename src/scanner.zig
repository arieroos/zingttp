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
            Token.value => .{ "value", self.value },
            Token.keyword => .{ "keyword", @tagName(self.keyword) },
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
            Token.value => false,
            Token.keyword => self.keyword == keyword,
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
                    Token{ .value = lexeme };

            try tokenList.append(TokenInfo{ .token = tokenType, .lexeme = lexeme, .pos = start });
        }

        start = end + 1;
    }

    return tokenList;
}

fn scanNextToken(line: []const u8, start: usize) usize {
    var current = start;
    while (current < line.len and line[current] != ' ') {
        current += 1;
    }
    return current;
}

const expect = std.testing.expect;
const testAllocator = std.testing.allocator;

test "token.toString should work for large value" {
    const str = "This_is_a_very_long_string,_it_must_have_at_least_128_characters_in_my_opinions,_though_121_should_be_fine_too!JustMakeSureItIsVeryLong...";

    var buffer: [32]u8 = undefined;
    const testTokenType = Token{ .value = str };
    try expect(std.mem.startsWith(u8, testTokenType.toString(&buffer), "value: This_is_a_very_long_strin"));
}

fn expectTokenToBeKeywordAt(token: TokenInfo, kw: Keyword, position: usize) !void {
    try expect(token.token.keyword == kw);
    try expect(std.mem.eql(u8, token.lexeme, @tagName(kw)));
    try expect(token.pos == position);
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

        const secondToken = getTokens.items[1];
        try expect(std.mem.eql(u8, secondToken.token.value, "http://some_site.com"));
        try expect(std.mem.eql(u8, secondToken.lexeme, "http://some_site.com"));
        try expect(secondToken.pos == 4);
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
    const testStr = "012 456 789";
    const end = scanNextToken(testStr, 4);

    try expect(std.mem.eql(u8, testStr[4..end], "456"));
    try expect(end == 7);
}
