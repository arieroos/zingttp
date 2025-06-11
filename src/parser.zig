const std = @import("std");
const scanner = @import("scanner.zig");

const Keyword = scanner.Keyword;
const Token = scanner.Token;
const TokenList = scanner.TokenList;

const Command = struct {
    command: []const u8,
    argument: []const u8,
};

pub const Expression = union(enum) {
    nothing: void,
    exit: void,
    command: Command,
    invalid: []const u8,
};

const InvalidReason = enum {
    ShouldStartWithKeyword,
    UnexpectedToken,
    UnexpectedKeyword,
};

pub fn parse(tokenList: TokenList) !Expression {
    const tokens = tokenList.items;
    if (tokens.len < 1) {
        return Expression.nothing;
    }
    var errorBuf: [1024]u8 = undefined;

    const keyword = switch (tokens[0].token) {
        .keyword => tokens[0].token.keyword,
        else => return genInvalidExpression(InvalidReason.ShouldStartWithKeyword, &errorBuf, tokens[0]),
    };

    if (keyword == Keyword.EXIT) {
        if (tokens.len > 1) {
            return genInvalidExpression(InvalidReason.UnexpectedToken, &errorBuf, tokens[1]);
        }
        return Expression.exit;
    }

    if (tokens.len > 2) {
        return genInvalidExpression(InvalidReason.UnexpectedToken, &errorBuf, tokens[2]);
    }
    const cmd = @tagName(keyword);
    const arg = switch (tokens[1].token) {
        .value => tokens[1].token.value,
        else => return genInvalidExpression(InvalidReason.UnexpectedKeyword, &errorBuf, tokens[1]),
    };

    return Expression{ .command = .{ .command = cmd, .argument = arg } };
}

fn genInvalidExpression(comptime reason: InvalidReason, buffer: []u8, token: scanner.TokenInfo) Expression {
    const format = comptime switch (reason) {
        .ShouldStartWithKeyword => "Statement does not start with a keyword",
        .UnexpectedToken => "Unexpected token at {}: \"{s}\"",
        .UnexpectedKeyword => "Found keyword \"{s}\" at {}, but expected an argument",
    };
    const args = switch (reason) {
        .UnexpectedToken => .{ token.pos, token.lexeme },
        .UnexpectedKeyword => .{ token.lexeme, token.pos },
        else => .{},
    };
    return Expression{ .invalid = std.fmt.bufPrint(buffer, format, args) catch buffer };
}

const expect = std.testing.expect;
const testAllocator = std.testing.allocator;

fn genTestTokenList(tokens: []const Token) !TokenList {
    var tokenList = TokenList.init(testAllocator);

    var lengthSoFar: usize = 0;
    for (tokens) |token| {
        const lexeme = switch (token) {
            .keyword => @tagName(token.keyword),
            .value => token.value,
        };
        try tokenList.append(scanner.TokenInfo{ .token = token, .lexeme = lexeme, .pos = lengthSoFar });

        lengthSoFar += lexeme.len;
    }

    return tokenList;
}

test parse {
    {
        var noTokens = try TokenList.initCapacity(testAllocator, 0);
        defer noTokens.deinit();

        const expression = try parse(noTokens);
        try expect(expression == Expression.nothing);
    }
    {
        var exitExprTokens = try genTestTokenList(&[_]Token{Token{ .keyword = Keyword.EXIT }});
        defer exitExprTokens.deinit();

        const expression = try parse(exitExprTokens);
        try expect(expression == Expression.exit);
    }
    {
        var postExprTokens = try genTestTokenList(&[_]Token{
            Token{ .keyword = Keyword.POST },
            Token{ .value = "http://some_url.com" },
        });
        defer postExprTokens.deinit();

        const expression = try parse(postExprTokens);
        try expect(std.mem.eql(u8, expression.command.command, "POST"));
        try expect(std.mem.eql(u8, expression.command.argument, "http://some_url.com"));
    }
    {
        var tokens = try genTestTokenList(&[_]Token{
            Token{ .keyword = Keyword.EXIT },
            Token{ .value = "gg" },
        });
        defer tokens.deinit();

        const expression = try parse(tokens);
        switch (expression) {
            .invalid => try expect(true),
            else => try (expect(false)),
        }
    }
}

test "Generate Invalid Expresion For Unexpected Token" {
    var buf: [128]u8 = undefined;
    const msg = genInvalidExpression(InvalidReason.UnexpectedToken, &buf, scanner.TokenInfo{ .token = Token{ .keyword = Keyword.GET }, .lexeme = "GET", .pos = 77 });
    switch (msg) {
        .invalid => try expect(std.mem.eql(u8, msg.invalid, "Unexpected token at 77: \"GET\"")),
        else => try expect(false),
    }
}
