const std = @import("std");

const TokenType = union(enum) {
    value: []const u8,
    keyword: Keyword,

    pub fn toString(self: TokenType, buffer: []u8) []u8 {
        const typeStr, const valStr = switch (self) {
            TokenType.value => .{ "value", self.value },
            TokenType.keyword => .{ "keyword", @tagName(self.keyword) },
        };

        const maxValLen = @max(buffer.len - typeStr.len - 2, 0);
        const printVal = if (valStr.len <= maxValLen)
            valStr
        else
            valStr[0..maxValLen];
        return std.fmt.bufPrint(buffer, "{s}: {s}", .{ typeStr, printVal }) catch buffer;
    }

    pub fn isKeyword(self: TokenType, keyword: Keyword) bool {
        return switch (self) {
            TokenType.value => false,
            TokenType.keyword => self.keyword == keyword,
        };
    }
};

pub const Keyword = enum(u8) {
    // keywords
    EXIT,
    // keywords - http
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,
};

pub const Token = struct { type: TokenType, lexeme: []const u8, pos: usize };

pub const ScannerError = error{
    LineDoesNotStartWithKeyword,
};

pub fn scan(line: []const u8, allocator: std.mem.Allocator) !std.ArrayList(Token) {
    var start: usize = 0;

    var tokenList = std.ArrayList(Token).init(allocator);

    while (start < line.len) {
        const end = scanNextToken(line, start);

        if (end > start) {
            const lexeme = line[start..end];
            const tokenType = if (tokenList.items.len == 0)
                if (std.meta.stringToEnum(Keyword, lexeme)) |keyword|
                    TokenType{ .keyword = keyword }
                else
                    return ScannerError.LineDoesNotStartWithKeyword
            else
                TokenType{ .value = lexeme };

            try tokenList.append(Token{ .type = tokenType, .lexeme = lexeme, .pos = start });
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

test "token type toString should work for large value" {
    const str = "This_is_a_very_long_string,_it_must_have_at_least_128_characters_in_my_opinions,_though_121_should_be_fine_too!JustMakeSureItIsVeryLong...";

    var buffer: [32]u8 = undefined;
    const testTokenType = TokenType{ .value = str };
    try expect(std.mem.startsWith(u8, testTokenType.toString(&buffer), "value: This_is_a_very_long_strin"));
}

test scan {
    const exitToken = try scan("EXIT", testAllocator);
    defer exitToken.deinit();
    try expect(exitToken.items[0].type.keyword == Keyword.EXIT);
    try expect(std.mem.eql(u8, exitToken.items[0].lexeme, "EXIT"));
    try expect(exitToken.items[0].pos == 0);

    const getTokens = try scan("GET http://some_site.com", testAllocator);
    defer getTokens.deinit();

    const firstToken = getTokens.items[0];
    try expect(firstToken.type.keyword == Keyword.GET);
    try expect(std.mem.eql(u8, firstToken.lexeme, "GET"));
    try expect(firstToken.pos == 0);

    const secondToken = getTokens.items[1];
    try expect(std.mem.eql(u8, secondToken.type.value, "http://some_site.com"));
    try expect(std.mem.eql(u8, secondToken.lexeme, "http://some_site.com"));
    try expect(secondToken.pos == 4);

    const ret = scan("hjjj", testAllocator);
    if (ret) |_| {
        try expect(false);
    } else |err| {
        try expect(err == ScannerError.LineDoesNotStartWithKeyword);
    }
}

test "scan ingores spaces" {
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
    try expect(std.mem.startsWith(u8, tokens.items[1].type.toString(&buffer), "value: This_is_a_very_long_strin"));
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
