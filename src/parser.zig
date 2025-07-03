const std = @import("std");
const Allocator = std.mem.Allocator;

const strings = @import("strings.zig");
const String = strings.String;

const scanner = @import("scanner.zig");
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

    pub fn deinit(self: *Expression, allocator: Allocator) void {
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

pub fn parse(tokenList: TokenList, allocator: Allocator) !Expression {
    const tokens = tokenList.items;
    if (tokens.len < 1) {
        return Expression.nothing;
    }

    const keyword = switch (tokens[0].token) {
        .keyword => tokens[0].token.keyword,
        else => return genInvalidExpression(InvalidReason.ShouldStartWithKeyword, .{}, allocator),
    };

    const arguments = tokens[1..];
    return switch (keyword) {
        .EXIT => parseExit(arguments, allocator),
        .PRINT => parsePrint(arguments, allocator),
        .GET,
        .POST,
        .PUT,
        .DELETE,
        .HEAD,
        .OPTIONS,
        .TRACE,
        .CONNECT,
        => parseMethod(tokens[0], arguments, allocator),
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

fn parseExit(arguments: []TokenInfo, allocator: Allocator) Expression {
    if (arguments.len > 0) {
        return genInvalidExpression(
            InvalidReason.UnexpectedToken,
            .{
                .pos = arguments[0].pos,
                .lexeme = arguments[0].lexeme,
            },
            allocator,
        );
    }
    return Expression.exit;
}

fn parsePrint(arguments: []TokenInfo, allocator: Allocator) !Expression {
    var arg_buffer: [1]ArgList = undefined;
    const args = try parseArgs(arguments, &arg_buffer, allocator);
    if (args.invalid) |i| {
        for (arg_buffer[0..args.arg_count]) |*a| {
            a.clearAndFree();
        }
        return i;
    }

    return Expression{ .print = arg_buffer[0] };
}

fn parseMethod(token: TokenInfo, arguments: []TokenInfo, allocator: Allocator) !Expression {
    var arg_buffer: [1]ArgList = undefined;
    const args = try parseArgs(arguments, &arg_buffer, allocator);
    if (args.invalid) |i| {
        for (arg_buffer[0..args.arg_count]) |*a| {
            a.clearAndFree();
        }
        return i;
    }

    return if (args.arg_count == 1 and arg_buffer[0].items.len > 0)
        Expression{ .request = .{
            .method = @tagName(token.token.keyword),
            .arguments = arg_buffer[0],
        } }
    else
        genInvalidExpression(
            InvalidReason.MissingToken,
            .{
                .expected = "value or variable",
                .pos = token.pos + token.lexeme.len,
            },
            allocator,
        );
}

const GetArgResult = struct {
    invalid: ?Expression = null,
    arg_count: usize,

    fn initInvalid(count: usize, token: TokenInfo, allocator: Allocator) GetArgResult {
        return GetArgResult{
            .invalid = genInvalidExpression(
                InvalidReason.ExpectedOther,
                .{
                    .expected = "value or variable",
                    .found = @tagName(token.token),
                    .pos = token.pos,
                    .lexeme = token.lexeme,
                },
                allocator,
            ),
            .arg_count = count,
        };
    }
};

fn parseArgs(tokens: []TokenInfo, arg_buffer: []ArgList, allocator: Allocator) !GetArgResult {
    if (tokens.len == 0) {
        return GetArgResult{ .arg_count = 0 };
    }
    switch (tokens[0].token) {
        .whitespace => {},
        else => return GetArgResult.initInvalid(0, tokens[0], allocator),
    }
    arg_buffer[0] = ArgList.init(allocator);

    const max_args = arg_buffer.len;
    var idx: usize = 0;
    for (tokens[1..]) |token| {
        switch (token.token) {
            .whitespace => {
                idx += 1;
                if (idx == max_args)
                    return GetArgResult.initInvalid(idx, token, allocator);

                std.debug.assert(idx < max_args);
                arg_buffer[idx] = ArgList.init(allocator);
            },
            .value => |v| try arg_buffer[idx].append(Argument{ .value = v }),
            .variable => |v| try arg_buffer[idx].append(Argument{ .variable = v }),
            else => {
                return GetArgResult.initInvalid(idx + 1, token, allocator);
            },
        }
    }

    return GetArgResult{ .arg_count = idx + 1 };
}

fn genInvalidExpression(
    comptime reason: InvalidReason,
    args: InvalidArgs(reason),
    allocator: Allocator,
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

fn expectArgumentAt(args: ArgList, idx: usize, val: String) !void {
    try expect(args.items.len > idx);
    const arg = args.items[idx];

    switch (arg) {
        .value, .variable => |v| try expectEqualStrings(val, v),
    }
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
        try expectArgumentAt(expression.request.arguments, 0, "http://some_url.com");
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
    {
        var tokens = try genTestTokenList(&[_]Token{
            Token{ .keyword = Keyword.PRINT },
            Token{ .whitespace = 1 },
            Token{ .value = "gg" },
            Token{ .variable = "some.variable" },
        });
        defer tokens.deinit();

        var expression = try parse(tokens, test_allocator);
        defer expression.deinit(test_allocator);

        try expectArgumentAt(expression.print, 0, "gg");
        try expectArgumentAt(expression.print, 1, "some.variable");
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

test "parseArgs parses args" {
    var tokens = try genTestTokenList(&[_]Token{
        Token{ .whitespace = 1 },
        Token{ .value = "PUT" },
        Token{ .value = "some value" },
        Token{ .whitespace = 2 },
        Token{ .variable = "a.variable" },
    });
    defer tokens.deinit();

    var args_buffer: [2]ArgList = undefined;
    const args = try parseArgs(tokens.items, &args_buffer, test_allocator);
    defer for (0..args.arg_count) |i| {
        args_buffer[i].clearAndFree();
    };

    try expect(args.invalid == null);
    if (args.arg_count != 2) {
        std.log.err("Expected arg count {}, but got {}\n", .{ 2, args.arg_count });
        try expect(false);
    }
    if (args_buffer[0].items.len != 2) {
        std.log.err("Expected {} args, but got {}\n", .{ 2, args_buffer[0].items.len });
        try expect(false);
    }
    try expect(args_buffer[1].items.len == 1);
}

test "parseArgs can do invalids" {
    const cases = &[_]TokenList{
        try genTestTokenList(&[_]Token{
            Token{ .value = "some value" },
        }),
        try genTestTokenList(&[_]Token{
            Token{ .value = "some value" },
            Token{ .keyword = Keyword.SET },
        }),
        try genTestTokenList(&[_]Token{
            Token{ .value = "some value" },
            Token{ .whitespace = 2 },
            Token{ .variable = "some variable" },
        }),
    };

    inline for (cases) |tokens| {
        defer tokens.deinit();

        var args_buffer: [2]ArgList = undefined;
        const args = try parseArgs(tokens.items, &args_buffer, test_allocator);
        defer for (0..args.arg_count) |i| {
            args_buffer[i].clearAndFree();
        };

        try expect(args.invalid != null);
        test_allocator.free(args.invalid.?.invalid);
    }
}

test "genInvalidExpression Generate Invalid Expresion For Unexpected Token" {
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
