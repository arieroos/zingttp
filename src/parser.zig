const std = @import("std");
const Allocator = std.mem.Allocator;

const strings = @import("strings.zig");
const String = strings.String;

const scanner = @import("scanner.zig");
const Keyword = scanner.Keyword;
const Token = scanner.Token;
const TokenInfo = scanner.TokenInfo;
const TokenList = scanner.TokenList;

pub const Value = union(enum) {
    value: String,
    variable: String,
};

pub const Values = std.ArrayList(Value);

pub const Request = struct {
    method: String,
    value: Values,
};

pub const SetArgs = struct {
    variable: Values,
    value: Values,
};

pub const Expression = union(enum) {
    nothing: void,
    exit: void,
    request: Request,
    print: Values,
    set: SetArgs,
    invalid: String,

    pub fn deinit(self: *Expression, allocator: Allocator) void {
        switch (self.*) {
            .request => |*r| r.value.clearAndFree(),
            .set => |*s| {
                s.value.clearAndFree();
                s.variable.clearAndFree();
            },
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
        .SET => parseSet(tokens[0], arguments, allocator),
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
            .{ .pos = 0, .lexeme = tokens[0].lexeme },
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
    var arg_buffer: [1]Values = undefined;
    const args = try parseArgs(arguments, &arg_buffer, allocator);
    if (args.invalid) |i| {
        for (arg_buffer[0..args.arg_count]) |*a| {
            a.clearAndFree();
        }
        return i;
    }
    if (args.arg_count == 0) {
        arg_buffer[0] = Values.init(allocator);
    }

    return Expression{ .print = arg_buffer[0] };
}

fn parseSet(token: TokenInfo, arguments: []TokenInfo, allocator: Allocator) !Expression {
    var arg_buffer: [2]Values = undefined;
    const args = try parseArgs(arguments, &arg_buffer, allocator);
    if (args.invalid) |i| {
        for (arg_buffer[0..args.arg_count]) |*a| {
            a.clearAndFree();
        }
        return i;
    }

    if (args.arg_count == 0 or arg_buffer[0].items.len == 0) {
        return genInvalidExpression(
            InvalidReason.MissingToken,
            .{
                .expected = "value or variable",
                .pos = token.pos + token.lexeme.len,
            },
            allocator,
        );
    }

    const value_args = if (args.arg_count == 2) arg_buffer[1] else Values.init(allocator);
    return Expression{ .set = .{ .variable = arg_buffer[0], .value = value_args } };
}

fn parseMethod(token: TokenInfo, arguments: []TokenInfo, allocator: Allocator) !Expression {
    var arg_buffer: [1]Values = undefined;
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
            .value = arg_buffer[0],
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

fn parseArgs(tokens: []TokenInfo, arg_buffer: []Values, allocator: Allocator) !GetArgResult {
    if (tokens.len == 0) {
        return GetArgResult{ .arg_count = 0 };
    }
    switch (tokens[0].token) {
        .whitespace => {},
        else => return GetArgResult.initInvalid(0, tokens[0], allocator),
    }
    arg_buffer[0] = Values.init(allocator);

    const max_args = arg_buffer.len;
    var idx: usize = 0;
    for (tokens[1..]) |token| {
        switch (token.token) {
            .whitespace => {
                idx += 1;
                if (idx == max_args)
                    return GetArgResult.initInvalid(idx, token, allocator);

                std.debug.assert(idx < max_args);
                arg_buffer[idx] = Values.init(allocator);
            },
            inline .literal, .quoted => |v| try arg_buffer[idx].append(Value{ .value = v }),
            .identifiers => |v| try arg_buffer[idx].append(Value{ .variable = v[0] }),
            .expression => continue,
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
            .operator => |o| if (strings.indexOfScalar(scanner.operators, o)) |i| scanner.operators[i .. i + 1] else return error.InvalidOperator,
            .expression => |e| if (e) "(" else ")",
            .subroutine => |s| if (s) "{" else "}",
            .identifiers => |i| if (i.len > 0) i[0] else "",
            inline else => |v| v,
        };
        try tokenList.append(TokenInfo{ .token = token, .lexeme = lexeme, .pos = lengthSoFar, .line = 0, .allocator = test_allocator });

        lengthSoFar += lexeme.len;
    }

    return tokenList;
}

fn expectArgumentAt(args: Values, idx: usize, val: String) !void {
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
            Token{ .literal = "http://some_url.com" },
        });
        defer postExprTokens.deinit();

        var expression = try parse(postExprTokens, test_allocator);
        defer expression.deinit(test_allocator);

        try expectEqualStrings("POST", expression.request.method);
        try expectArgumentAt(expression.request.value, 0, "http://some_url.com");
    }
    {
        var tokens = try genTestTokenList(&[_]Token{
            Token{ .keyword = Keyword.EXIT },
            Token{ .whitespace = 1 },
            Token{ .literal = "gg" },
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
            Token{ .literal = "gg" },
            Token{ .identifiers = &[_]String{ "some", "variable" } },
            Token{ .quoted = "ggg" },
        });
        defer tokens.deinit();

        var expression = try parse(tokens, test_allocator);
        defer expression.deinit(test_allocator);

        try expectArgumentAt(expression.print, 0, "gg");
        try expectArgumentAt(expression.print, 1, "some.variable");
        try expectArgumentAt(expression.print, 2, "ggg");
    }
    {
        var tokens = try genTestTokenList(&[_]Token{
            Token{ .keyword = Keyword.SET },
            Token{ .whitespace = 1 },
            Token{ .literal = "gg" },
            Token{ .whitespace = 1 },
            Token{ .identifiers = &[_]String{ "some", "variable" } },
            Token{ .literal = ".literal" },
        });
        defer tokens.deinit();

        var expression = try parse(tokens, test_allocator);
        defer expression.deinit(test_allocator);

        try expectArgumentAt(expression.set.variable, 0, "gg");
        try expectArgumentAt(expression.set.value, 0, "some.variable");
        try expectArgumentAt(expression.set.value, 1, ".literal");
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

test "parsePrint can parse 0 args" {
    var expression = try parsePrint(&[_]TokenInfo{}, test_allocator);
    defer expression.deinit(test_allocator);

    for (expression.print.items) |_| {
        try expect(false);
    }
}

test "parseArgs parses args" {
    var tokens = try genTestTokenList(&[_]Token{
        Token{ .whitespace = 1 },
        Token{ .literal = "PUT" },
        Token{ .quoted = "some value" },
        Token{ .whitespace = 2 },
        Token{ .literal = "a.variable" },
    });
    defer tokens.deinit();

    var args_buffer: [2]Values = undefined;
    var args = try parseArgs(tokens.items, &args_buffer, test_allocator);
    defer for (0..args.arg_count) |i| {
        args_buffer[i].clearAndFree();
    };
    defer if (args.invalid) |*i| {
        i.deinit(test_allocator);
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
            Token{ .literal = "some value" },
        }),
        try genTestTokenList(&[_]Token{
            Token{ .literal = "some value" },
            Token{ .keyword = Keyword.SET },
        }),
        try genTestTokenList(&[_]Token{
            Token{ .literal = "some value" },
            Token{ .whitespace = 2 },
            Token{ .identifiers = &[_]String{"some variable"} },
        }),
    };

    inline for (cases) |tokens| {
        defer tokens.deinit();

        var args_buffer: [2]Values = undefined;
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
