const std = @import("std");
const scanner = @import("scanner.zig");

const Keyword = scanner.Keyword;
const Token = scanner.Token;
const TokenInfo = scanner.TokenInfo;
const TokenList = scanner.TokenList;

pub const Command = struct {
    command: []const u8,
    argument: []const u8,
};

const Invalid = struct { buffer: [1024]u8, message: []u8 };

pub const Expression = union(enum) {
    nothing: void,
    exit: void,
    command: Command,
    invalid: Invalid,
};

const InvalidReason = enum {
    ShouldStartWithKeyword,
    UnexpectedToken,
    ExpectedOther,
    MissingToken,
};

fn InvalidArgs(comptime reason: InvalidReason) type {
    return switch (reason) {
        .UnexpectedToken => struct {
            pos: usize,
            lexeme: []const u8,
        },
        .ExpectedOther => struct {
            expected: []const u8,
            found: []const u8,
            pos: usize,
            lexeme: []const u8,
        },
        .MissingToken => struct {
            expected: []const u8,
            pos: usize,
        },
        inline else => struct {},
    };
}

pub fn parse(tokenList: TokenList) !Expression {
    const tokens = tokenList.items;
    if (tokens.len < 1) {
        return Expression.nothing;
    }

    const keyword = switch (tokens[0].token) {
        .keyword => tokens[0].token.keyword,
        else => return genInvalidExpression(InvalidReason.ShouldStartWithKeyword, .{}),
    };

    if (keyword == Keyword.EXIT) {
        if (tokens.len > 1) {
            return genInvalidExpression(InvalidReason.UnexpectedToken, .{
                .pos = tokens[1].pos,
                .lexeme = tokens[1].lexeme,
            });
        }
        return Expression.exit;
    }

    if (tokens.len > 2) {
        return genInvalidExpression(InvalidReason.UnexpectedToken, .{
            .pos = tokens[2].pos,
            .lexeme = tokens[2].lexeme,
        });
    }
    if (tokens.len < 2) {
        return genInvalidExpression(InvalidReason.MissingToken, .{
            .expected = "value",
            .pos = tokens[0].pos + tokens[0].lexeme.len + 1,
        });
    }
    const cmd = @tagName(keyword);
    const arg = switch (tokens[1].token) {
        .value => |v| v,
        else => return genInvalidExpression(InvalidReason.ExpectedOther, .{
            .expected = "value",
            .found = @tagName(tokens[1].token),
            .pos = tokens[1].pos,
            .lexeme = tokens[1].lexeme,
        }),
    };

    return Expression{ .command = .{ .command = cmd, .argument = arg } };
}

fn genInvalidExpression(comptime reason: InvalidReason, args: InvalidArgs(reason)) Expression {
    const format = comptime switch (reason) {
        .ShouldStartWithKeyword => "Statement does not start with keyword",
        .UnexpectedToken => "Unexpected token at {}: \"{s}\"",
        .ExpectedOther => "Expected {s} but found {s} at {}: \"{s}\"",
        .MissingToken => "Missing {s} at {}",
    };

    var buffer: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buffer, format, args) catch &buffer;
    return Expression{ .invalid = Invalid{ .buffer = buffer, .message = msg } };
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const testAllocator = std.testing.allocator;

fn genTestTokenList(tokens: []const Token) !TokenList {
    var tokenList = TokenList.init(testAllocator);

    var lengthSoFar: usize = 0;
    for (tokens) |token| {
        const lexeme = switch (token) {
            .keyword => @tagName(token.keyword),
            inline else => |v| v,
        };
        try tokenList.append(TokenInfo{ .token = token, .lexeme = lexeme, .pos = lengthSoFar });

        lengthSoFar += lexeme.len + 1;
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
            .invalid => |inv| try expectEqualStrings("Unexpected token at 5: \"gg\"", inv.message),
            else => try (expect(false)),
        }
    }
}

test "parse breaks on command without arg" {
    var tokens = try genTestTokenList(&[_]Token{Token{ .keyword = Keyword.PUT }});
    defer tokens.deinit();

    const expression = try parse(tokens);
    switch (expression) {
        .invalid => |inv| try expectEqualStrings("Missing value at 4", inv.message),
        else => try (expect(false)),
    }
}

test "generateInvalidExpression Generate Invalid Expresion For Unexpected Token" {
    const msg = genInvalidExpression(InvalidReason.UnexpectedToken, .{ .pos = 77, .lexeme = "GET" });
    switch (msg) {
        .invalid => |inv| try expectEqualStrings(inv.message, "Unexpected token at 77: \"GET\""),
        else => try expect(false),
    }
}
