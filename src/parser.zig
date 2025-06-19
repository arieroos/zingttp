const std = @import("std");
const scanner = @import("scanner.zig");

const strings = @import("strings.zig");
const String = strings.String;

const Keyword = scanner.Keyword;
const Token = scanner.Token;
const TokenInfo = scanner.TokenInfo;
const TokenList = scanner.TokenList;

pub const Argument = union(enum) {
    value: String,
    variable: String,
};

pub const ArgList = std.ArrayList(Argument);

pub const Request = struct {
    method: String,
    arguments: ArgList,
};

pub const Expression = union(enum) {
    nothing: void,
    exit: void,
    request: Request,
    print: ArgList,
    invalid: String,

    pub fn deinit(self: *Expression, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .request => |*r| r.arguments.clearAndFree(),
            .print => |*p| p.clearAndFree(),
            .invalid => |i| allocator.free(i),
            else => {},
        }
    }
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
            lexeme: String,
        },
        .ExpectedOther => struct {
            expected: String,
            found: String,
            pos: usize,
            lexeme: String,
        },
        .MissingToken => struct {
            expected: String,
            pos: usize,
        },
        inline else => struct {},
    };
}

pub fn parse(tokenList: TokenList, allocator: std.mem.Allocator) !Expression {
    const tokens = tokenList.items;
    if (tokens.len < 1) {
        return Expression.nothing;
    }

    const keyword = switch (tokens[0].token) {
        .keyword => tokens[0].token.keyword,
        else => return genInvalidExpression(InvalidReason.ShouldStartWithKeyword, .{}, allocator),
    };

    if (keyword == Keyword.EXIT) {
        if (tokens.len > 1) {
            return genInvalidExpression(
                InvalidReason.UnexpectedToken,
                .{
                    .pos = tokens[1].pos,
                    .lexeme = tokens[1].lexeme,
                },
                allocator,
            );
        }
        return Expression.exit;
    }

    if (tokens.len > 1) {
        switch (tokens[1].token) {
            .whitespace => {},
            else => return genInvalidExpression(
                InvalidReason.ExpectedOther,
                .{
                    .expected = "whitespace",
                    .found = @tagName(tokens[1].token),
                    .pos = tokens[1].pos,
                    .lexeme = tokens[1].lexeme,
                },
                allocator,
            ),
        }
    }

    const args = if (tokens.len > 2)
        try getArgs(tokens[2..], allocator)
    else
        GetArgResult{ .args = ArgList.init(allocator) };

    switch (args) {
        .invalid => |i| return i,
        else => {},
    }

    return switch (keyword) {
        .GET,
        .POST,
        .PUT,
        .DELETE,
        .HEAD,
        .OPTIONS,
        .TRACE,
        .CONNECT,
        => if (args.args.items.len > 0)
            Expression{ .request = .{ .method = @tagName(keyword), .arguments = args.args } }
        else
            genInvalidExpression(
                InvalidReason.MissingToken,
                .{
                    .expected = "value or variable",
                    .pos = tokens[0].pos + tokens[0].lexeme.len,
                },
                allocator,
            ),
        .PRINT => Expression{ .print = args.args },
        else => genInvalidExpression(
            InvalidReason.UnexpectedToken,
            .{
                .pos = 0,
                .lexeme = tokens[0].lexeme,
            },
            allocator,
        ),
    };
}

const GetArgResult = union(enum) {
    invalid: Expression,
    args: ArgList,
};

fn getArgs(tokens: []TokenInfo, allocator: std.mem.Allocator) !GetArgResult {
    var args = ArgList.init(allocator);
    errdefer args.clearAndFree();

    for (tokens) |token| {
        switch (token.token) {
            .value => |v| try args.append(Argument{ .value = v }),
            .variable => |v| try args.append(Argument{ .variable = v }),
            else => {
                defer args.clearAndFree();
                return GetArgResult{ .invalid = genInvalidExpression(
                    InvalidReason.ExpectedOther,
                    .{
                        .expected = "value or variable",
                        .found = @tagName(token.token),
                        .pos = token.pos,
                        .lexeme = token.lexeme,
                    },
                    allocator,
                ) };
            },
        }
    }

    return GetArgResult{ .args = args };
}

fn genInvalidExpression(
    comptime reason: InvalidReason,
    args: InvalidArgs(reason),
    allocator: std.mem.Allocator,
) Expression {
    const format = comptime switch (reason) {
        .ShouldStartWithKeyword => "Statement does not start with keyword",
        .UnexpectedToken => "Unexpected token at {}: \"{s}\"",
        .ExpectedOther => "Expected {s} but found {s} at {}: \"{s}\"",
        .MissingToken => "Missing {s} at {}",
    };

    const msg = std.fmt.allocPrint(
        allocator,
        format,
        args,
    ) catch "Not enough memory to store invalid reason.";
    return Expression{ .invalid = msg };
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const test_allocator = std.testing.allocator;

fn genTestTokenList(tokens: []const Token) !TokenList {
    var tokenList = TokenList.init(test_allocator);

    var lengthSoFar: usize = 0;
    for (tokens) |token| {
        const lexeme = switch (token) {
            .keyword => @tagName(token.keyword),
            .whitespace => " ",
            inline else => |v| v,
        };
        try tokenList.append(TokenInfo{ .token = token, .lexeme = lexeme, .pos = lengthSoFar });

        lengthSoFar += lexeme.len;
    }

    return tokenList;
}

test parse {
    {
        var noTokens = try TokenList.initCapacity(test_allocator, 0);
        defer noTokens.deinit();

        var expression = try parse(noTokens, test_allocator);
        defer expression.deinit(test_allocator);

        try expect(expression == Expression.nothing);
    }
    {
        var exitExprTokens = try genTestTokenList(&[_]Token{Token{ .keyword = Keyword.EXIT }});
        defer exitExprTokens.deinit();

        var expression = try parse(exitExprTokens, test_allocator);
        defer expression.deinit(test_allocator);

        try expect(expression == Expression.exit);
    }
    {
        var postExprTokens = try genTestTokenList(&[_]Token{
            Token{ .keyword = Keyword.POST },
            Token{ .whitespace = 1 },
            Token{ .value = "http://some_url.com" },
        });
        defer postExprTokens.deinit();

        var expression = try parse(postExprTokens, test_allocator);
        defer expression.deinit(test_allocator);

        try expectEqualStrings("POST", expression.request.method);
        try expectEqualStrings("http://some_url.com", expression.request.arguments.items[0].value);
    }
    {
        var tokens = try genTestTokenList(&[_]Token{
            Token{ .keyword = Keyword.EXIT },
            Token{ .whitespace = 1 },
            Token{ .value = "gg" },
        });
        defer tokens.deinit();

        var expression = try parse(tokens, test_allocator);
        defer expression.deinit(test_allocator);

        switch (expression) {
            .invalid => |inv| try expectEqualStrings("Unexpected token at 4: \" \"", inv),
            else => try (expect(false)),
        }
    }
}

test "parse breaks on command without arg" {
    var tokens = try genTestTokenList(&[_]Token{Token{ .keyword = Keyword.PUT }});
    defer tokens.deinit();

    var expression = try parse(tokens, test_allocator);
    defer expression.deinit(test_allocator);

    switch (expression) {
        .invalid => |inv| try expectEqualStrings("Missing value or variable at 3", inv),
        else => try (expect(false)),
    }
}

test "generateInvalidExpression Generate Invalid Expresion For Unexpected Token" {
    const msg = genInvalidExpression(
        InvalidReason.UnexpectedToken,
        .{ .pos = 77, .lexeme = "GET" },
        test_allocator,
    );
    defer test_allocator.free(msg.invalid);

    switch (msg) {
        .invalid => |inv| try expectEqualStrings(inv, "Unexpected token at 77: \"GET\""),
        else => try expect(false),
    }
}
