const std = @import("std");
const Allocator = std.mem.Allocator;

const strings = @import("strings.zig");
const String = strings.String;

const tokens = @import("tokens.zig");
const Keyword = tokens.Keyword;
const Token = tokens.Token;
const TokenValue = tokens.TokenValue;
const TokenList = tokens.TokenList;

const Expression = []*Token;

pub const Value = union(enum) {
    value: String,
    expession: Expression,
};
pub const Values = std.ArrayList(Value);

pub fn deinitValues(values: *Values, allocator: Allocator) void {
    for (values.items) |*value| {
        switch (value.*) {
            .value => {},
            .expession => |e| allocator.free(e),
        }
    }
    values.clearAndFree();
}

pub const Request = struct {
    method: String,
    value: Values,
};

pub const SetArgs = struct {
    variable: Values,
    value: Values,
};

const Statement = union(enum) {
    nothing: void,
    exit: void,
    request: Request,
    print: Values,
    set: SetArgs,
    invalid: String,

    pub fn deinit(self: *Statement, allocator: Allocator) void {
        switch (self.*) {
            .request => |*r| deinitValues(&r.value, allocator),
            .set => |*s| {
                deinitValues(&s.value, allocator);
                deinitValues(&s.variable, allocator);
            },
            .print => |*p| deinitValues(p, allocator),
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

pub fn parse(tokenList: TokenList, allocator: Allocator) !Statement {
    const token_list = tokenList.items;
    if (token_list.len < 1) {
        return Statement.nothing;
    }

    const keyword = switch (token_list[0].value) {
        .keyword => token_list[0].value.keyword,
        else => return genInvalidStatement(InvalidReason.ShouldStartWithKeyword, .{}, allocator),
    };

    const arguments = token_list[1..];
    return switch (keyword) {
        .EXIT => parseExit(arguments, allocator),
        .PRINT => parsePrint(arguments, allocator),
        .SET => parseSet(token_list[0], arguments, allocator),
        .GET,
        .POST,
        .PUT,
        .DELETE,
        .HEAD,
        .OPTIONS,
        .TRACE,
        .CONNECT,
        => parseMethod(token_list[0], arguments, allocator),
        else => genInvalidStatement(
            InvalidReason.UnexpectedToken,
            .{ .pos = 0, .lexeme = token_list[0].lexeme },
            allocator,
        ),
    };
}

fn parseExit(arguments: []Token, allocator: Allocator) Statement {
    if (arguments.len > 0) {
        return genInvalidStatement(
            InvalidReason.UnexpectedToken,
            .{
                .pos = arguments[0].pos,
                .lexeme = arguments[0].lexeme,
            },
            allocator,
        );
    }
    return Statement.exit;
}

fn parsePrint(arguments: []Token, allocator: Allocator) !Statement {
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

    return Statement{ .print = arg_buffer[0] };
}

fn parseSet(token: Token, arguments: []Token, allocator: Allocator) !Statement {
    var arg_buffer: [2]Values = undefined;
    const args = try parseArgs(arguments, &arg_buffer, allocator);
    if (args.invalid) |i| {
        for (arg_buffer[0..args.arg_count]) |*a| {
            a.clearAndFree();
        }
        return i;
    }

    if (args.arg_count == 0 or arg_buffer[0].items.len == 0) {
        return genInvalidStatement(
            InvalidReason.MissingToken,
            .{
                .expected = "value or variable",
                .pos = token.pos + token.lexeme.len,
            },
            allocator,
        );
    }

    const value_args = if (args.arg_count == 2) arg_buffer[1] else Values.init(allocator);
    return Statement{ .set = .{ .variable = arg_buffer[0], .value = value_args } };
}

fn parseMethod(token: Token, arguments: []Token, allocator: Allocator) !Statement {
    var arg_buffer: [1]Values = undefined;
    const args = try parseArgs(arguments, &arg_buffer, allocator);
    if (args.invalid) |i| {
        for (arg_buffer[0..args.arg_count]) |*a| {
            a.clearAndFree();
        }
        return i;
    }

    return if (args.arg_count == 1 and arg_buffer[0].items.len > 0)
        Statement{ .request = .{
            .method = @tagName(token.value.keyword),
            .value = arg_buffer[0],
        } }
    else
        genInvalidStatement(
            InvalidReason.MissingToken,
            .{
                .expected = "value or variable",
                .pos = token.pos + token.lexeme.len,
            },
            allocator,
        );
}

const GetArgResult = struct {
    invalid: ?Statement = null,
    arg_count: usize,

    fn initInvalid(count: usize, token: Token, allocator: Allocator) GetArgResult {
        return GetArgResult{
            .invalid = genInvalidStatement(
                InvalidReason.ExpectedOther,
                .{
                    .expected = "value or variable",
                    .found = @tagName(token.value),
                    .pos = token.pos,
                    .lexeme = token.lexeme,
                },
                allocator,
            ),
            .arg_count = count,
        };
    }
};

fn parseArgs(token_list: []Token, arg_buffer: []Values, allocator: Allocator) !GetArgResult {
    if (token_list.len == 0) {
        return GetArgResult{ .arg_count = 0 };
    }
    if (token_list[0].value != .whitespace) {
        return GetArgResult.initInvalid(0, token_list[0], allocator);
    }
    arg_buffer[0] = Values.init(allocator);

    const max_args = arg_buffer.len;
    var idx: usize = 0;
    for (token_list[1..]) |token| {
        switch (token.value) {
            .whitespace => {
                idx += 1;
                if (idx == max_args)
                    return GetArgResult.initInvalid(idx, token, allocator);

                std.debug.assert(idx < max_args);
                arg_buffer[idx] = Values.init(allocator);
            },
            inline .literal, .quoted => |v| try arg_buffer[idx].append(Value{ .value = v }),
            //         .identifiers => |v| try arg_buffer[idx].append(Value{ .variable = v[0] }),
            .expression => continue,
            else => {
                return GetArgResult.initInvalid(idx + 1, token, allocator);
            },
        }
    }

    return GetArgResult{ .arg_count = idx + 1 };
}

fn genInvalidStatement(
    comptime reason: InvalidReason,
    args: InvalidArgs(reason),
    allocator: Allocator,
) Statement {
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
    return Statement{ .invalid = msg };
}

fn parseExpression(token_list: []Token, allocator: std.mem.Allocator) !Expression {
    var output = try std.ArrayList(*Token).initCapacity(allocator, token_list.len);
    var op_stack = std.ArrayList(*Token).init(allocator);
    defer op_stack.deinit();

    for (token_list) |*token| {
        switch (token.value) {
            .identifiers, .quoted => output.appendAssumeCapacity(token),
            .operator => |op| {
                while (op_stack.items.len > 0) {
                    const item = op_stack.items[op_stack.items.len - 1].value;
                    if (item != .operator) break;
                    if (op.order() < item.operator.order()) break;
                    output.appendAssumeCapacity(op_stack.pop().?);
                }
                try op_stack.append(token);
            },
            .expression => |e| if (e) try op_stack.append(token) else {
                while (op_stack.pop()) |o| {
                    if (o.value == .expression) {
                        break;
                    }
                    output.appendAssumeCapacity(o);
                }
            },
            else => return error.UnexpectedToken,
        }
    }
    while (op_stack.pop()) |o| {
        if (o.value == .expression) {
            std.debug.assert(op_stack.items.len == 0);
            continue;
        }
        output.appendAssumeCapacity(o);
    }

    return try output.toOwnedSlice();
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const test_allocator = std.testing.allocator;

fn genTestTokenList(token_list: []const TokenValue) !TokenList {
    var tokenList = TokenList.init(test_allocator);

    var lengthSoFar: usize = 0;
    for (token_list) |token| {
        const owned_token = switch (token) {
            .identifiers => |i| allocate: {
                const new_mem = try test_allocator.alloc(String, i.len);
                std.mem.copyForwards(String, new_mem, i);
                break :allocate tokens.TokenValue{ .identifiers = new_mem };
            },
            else => token,
        };

        const lexeme = switch (token) {
            .keyword => @tagName(token.keyword),
            .whitespace => " ",
            .operator => |o| o.toString(),
            .expression => |e| if (e) "(" else ")",
            .subroutine => |s| if (s) "{" else "}",
            .identifiers => |i| if (i.len > 0) i[0] else "",
            inline else => |v| v,
        };
        try tokenList.append(Token{
            .value = owned_token,
            .lexeme = try strings.toOwned(lexeme, test_allocator),
            .pos = lengthSoFar,
            .line = 0,
            .allocator = test_allocator,
        });

        lengthSoFar += lexeme.len;
    }

    return tokenList;
}

fn expectValueAt(args: Values, idx: usize, val: String) !void {
    try expect(args.items.len > idx);
    const arg = args.items[idx];

    switch (arg) {
        .value => |v| try expectEqualStrings(val, v),
        .expession => try expect(false),
    }
}

test parse {
    {
        var noTokens = try TokenList.initCapacity(test_allocator, 0);
        defer noTokens.deinit();

        var expression = try parse(noTokens, test_allocator);
        defer expression.deinit(test_allocator);

        try expect(expression == Statement.nothing);
    }
    {
        var exitExprTokens = try genTestTokenList(&[_]TokenValue{.{ .keyword = Keyword.EXIT }});
        defer exitExprTokens.deinit();

        var expression = try parse(exitExprTokens, test_allocator);
        defer expression.deinit(test_allocator);

        try expect(expression == Statement.exit);
    }
    {
        var postExprTokens = try genTestTokenList(&[_]TokenValue{
            .{ .keyword = Keyword.POST },
            .{ .whitespace = 1 },
            .{ .literal = "http://some_url.com" },
        });
        defer postExprTokens.deinit();

        var expression = try parse(postExprTokens, test_allocator);
        defer expression.deinit(test_allocator);

        try expectEqualStrings("POST", expression.request.method);
        try expectValueAt(expression.request.value, 0, "http://some_url.com");
    }
    {
        var token_list = try genTestTokenList(&[_]TokenValue{
            .{ .keyword = Keyword.EXIT },
            .{ .whitespace = 1 },
            .{ .literal = "gg" },
        });
        defer token_list.deinit();

        var expression = try parse(token_list, test_allocator);
        defer expression.deinit(test_allocator);

        switch (expression) {
            .invalid => |inv| try expectEqualStrings("Unexpected token at 4: \" \"", inv),
            else => try (expect(false)),
        }
    }
    {
        var token_list = try genTestTokenList(&[_]TokenValue{
            .{ .keyword = Keyword.PRINT },
            .{ .whitespace = 1 },
            .{ .literal = "gg" },
            .{ .identifiers = &[_]String{ "some", "variable" } },
            .{ .quoted = "ggg" },
        });
        defer token_list.deinit();

        var expression = try parse(token_list, test_allocator);
        defer expression.deinit(test_allocator);

        try expectValueAt(expression.print, 0, "gg");
        try expectValueAt(expression.print, 1, "some.variable");
        try expectValueAt(expression.print, 2, "ggg");
    }
    {
        var token_list = try genTestTokenList(&[_]TokenValue{
            .{ .keyword = Keyword.SET },
            .{ .whitespace = 1 },
            .{ .literal = "gg" },
            .{ .whitespace = 1 },
            .{ .identifiers = &[_]String{ "some", "variable" } },
            .{ .literal = ".literal" },
        });
        defer token_list.deinit();

        var expression = try parse(token_list, test_allocator);
        defer expression.deinit(test_allocator);

        try expectValueAt(expression.set.variable, 0, "gg");
        try expectValueAt(expression.set.value, 0, "some.variable");
        try expectValueAt(expression.set.value, 1, ".literal");
    }
}

test "parse breaks on command without arg" {
    var token_list = try genTestTokenList(&[_]TokenValue{.{ .keyword = Keyword.PUT }});
    defer token_list.deinit();

    var expression = try parse(token_list, test_allocator);
    defer expression.deinit(test_allocator);

    switch (expression) {
        .invalid => |inv| try expectEqualStrings("Missing value or variable at 3", inv),
        else => try (expect(false)),
    }
}

test "parsePrint can parse 0 args" {
    var expression = try parsePrint(&[_]Token{}, test_allocator);
    defer expression.deinit(test_allocator);

    for (expression.print.items) |_| {
        try expect(false);
    }
}

test "parseArgs parses args" {
    var token_list = try genTestTokenList(&[_]TokenValue{
        .{ .whitespace = 1 },
        .{ .literal = "PUT" },
        .{ .quoted = "some value" },
        .{ .whitespace = 2 },
        .{ .literal = "a.variable" },
    });
    defer token_list.deinit();

    var args_buffer: [2]Values = undefined;
    var args = try parseArgs(token_list.items, &args_buffer, test_allocator);
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
        try genTestTokenList(&[_]TokenValue{
            .{ .literal = "some value" },
        }),
        try genTestTokenList(&[_]TokenValue{
            .{ .literal = "some value" },
            .{ .keyword = Keyword.SET },
        }),
        try genTestTokenList(&[_]TokenValue{
            .{ .literal = "some value" },
            .{ .whitespace = 2 },
            .{ .identifiers = &[_]String{"some variable"} },
        }),
    };

    inline for (cases) |token_list| {
        defer token_list.deinit();

        var args_buffer: [2]Values = undefined;
        const args = try parseArgs(token_list.items, &args_buffer, test_allocator);
        defer for (0..args.arg_count) |i| {
            args_buffer[i].clearAndFree();
        };

        try expect(args.invalid != null);
        test_allocator.free(args.invalid.?.invalid);
    }
}

test "genInvalidExpression Generate Invalid Expresion For Unexpected Token" {
    const msg = genInvalidStatement(
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

test "parseExpression can parse an expression" {
    const cases = &[_]struct { token_list: TokenList, expected: []const usize }{
        .{
            .token_list = try genTestTokenList(&[_]TokenValue{
                .{ .expression = true },
                .{ .identifiers = &[_]String{"32"} },
                .{ .expression = false },
            }),
            .expected = &[_]usize{1},
        },
        .{
            .token_list = try genTestTokenList(&[_]TokenValue{
                .{ .expression = true },
                .{ .identifiers = &[_]String{"1"} },
                .{ .operator = tokens.Operator.plus },
                .{ .identifiers = &[_]String{"2"} },
                .{ .expression = false },
            }),
            .expected = &[_]usize{ 1, 3, 2 },
        },
        .{
            .token_list = try genTestTokenList(&[_]TokenValue{
                .{ .expression = true },
                .{ .identifiers = &[_]String{"1"} },
                .{ .operator = tokens.Operator.plus },
                .{ .identifiers = &[_]String{"2"} },
                .{ .operator = tokens.Operator.exponent },
                .{ .identifiers = &[_]String{"3"} },
                .{ .expression = false },
            }),
            .expected = &[_]usize{ 1, 3, 5, 4, 2 },
        },
        .{
            .token_list = try genTestTokenList(&[_]TokenValue{
                .{ .expression = true },
                .{ .identifiers = &[_]String{"1"} },
                .{ .operator = tokens.Operator.exponent },
                .{ .identifiers = &[_]String{"2"} },
                .{ .operator = tokens.Operator.plus },
                .{ .identifiers = &[_]String{"3"} },
                .{ .expression = false },
            }),
            .expected = &[_]usize{ 1, 3, 2, 5, 4 },
        },
        .{
            .token_list = try genTestTokenList(&[_]TokenValue{
                .{ .expression = true },
                .{ .identifiers = &[_]String{"1"} },
                .{ .operator = tokens.Operator.exponent },
                .{ .expression = true },
                .{ .identifiers = &[_]String{"2"} },
                .{ .operator = tokens.Operator.plus },
                .{ .identifiers = &[_]String{"3"} },
                .{ .expression = false },
                .{ .expression = false },
            }),
            .expected = &[_]usize{ 1, 4, 6, 5, 2 },
        },
    };

    inline for (cases) |*case| {
        var token_list = case.token_list;
        defer tokens.deinitTokenList(&token_list);

        const expression = try parseExpression(case.token_list.items, test_allocator);
        defer test_allocator.free(expression);

        var expr_str = strings.StringBuilder.init(test_allocator);
        defer expr_str.clearAndFree();
        for (expression) |t| {
            if (expr_str.items.len > 0) {
                try expr_str.append(' ');
            }
            try expr_str.appendSlice(t.lexeme);
        }

        try expect(expression.len == case.expected.len);
        for (case.expected, expression) |idx, tkn| {
            if (&token_list.items[idx] != tkn) {
                std.log.err("{s}", .{expr_str.items});
                try expect(false);
            }
        }
    }
}
