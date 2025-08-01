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
    InvalidArgCount,
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
        .InvalidArgCount => struct {
            expected: usize,
            got: usize,
        },
        inline else => struct {},
    };
}

pub fn parse(token_list: TokenList, allocator: Allocator) !Statement {
    const token_slice = token_list.items;
    if (token_slice.len < 1) {
        return Statement.nothing;
    }

    const keyword = switch (token_slice[0].value) {
        .keyword => token_slice[0].value.keyword,
        else => return genInvalidStatement(InvalidReason.ShouldStartWithKeyword, .{}, allocator),
    };

    const arguments = token_slice[1..];
    return switch (keyword) {
        .EXIT => parseExit(arguments, allocator),
        .PRINT => parsePrint(arguments, allocator),
        .SET => parseSet(token_slice[0], arguments, allocator),
        .GET,
        .POST,
        .PUT,
        .DELETE,
        .HEAD,
        .OPTIONS,
        .TRACE,
        .CONNECT,
        => parseMethod(token_slice[0], arguments, allocator),
        else => genInvalidStatement(
            InvalidReason.UnexpectedToken,
            .{ .pos = 0, .lexeme = token_slice[0].lexeme },
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
    var args = try parseArgs(arguments, &arg_buffer, allocator);
    if (args.invalid) |i| {
        args.deinitArgBuffer();
        return i;
    }
    if (args.parsed_args == 0) {
        arg_buffer[0] = Values.init(allocator);
    }

    return Statement{ .print = arg_buffer[0] };
}

fn parseSet(token: Token, arguments: []Token, allocator: Allocator) !Statement {
    var arg_buffer: [2]Values = undefined;
    var args = try parseArgs(arguments, &arg_buffer, allocator);
    if (args.invalid) |i| {
        args.deinitArgBuffer();
        return i;
    }

    if (args.parsed_args == 0 or arg_buffer[0].items.len == 0) {
        return genInvalidStatement(
            InvalidReason.MissingToken,
            .{
                .expected = "value or variable",
                .pos = token.pos + token.lexeme.len,
            },
            allocator,
        );
    }

    const value_args = if (args.parsed_args == 2) arg_buffer[1] else Values.init(allocator);
    return Statement{ .set = .{ .variable = arg_buffer[0], .value = value_args } };
}

fn parseMethod(token: Token, arguments: []Token, allocator: Allocator) !Statement {
    var arg_buffer: [1]Values = undefined;
    var args = try parseArgs(arguments, &arg_buffer, allocator);
    if (args.invalid) |i| {
        args.deinitArgBuffer();
        return i;
    }

    return if (args.parsed_args == 1 and arg_buffer[0].items.len > 0)
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

fn parseArgs(arguments: []Token, arg_buffer: []Values, allocator: Allocator) !Args {
    if (arguments.len == 0) {
        return Args{
            .current_token = undefined,
            .allocator = allocator,
            .token_list = arguments,
            .arg_buffer = arg_buffer,
        };
    }

    var args = Args.init(arguments, arg_buffer, allocator);
    try args.parse();

    return args;
}

const Args = struct {
    current_idx: usize = 0,
    line_ended: bool = false,
    invalid: ?Statement = null,
    parsed_args: usize = 0,
    token_list: []Token,
    allocator: Allocator,
    current_token: *Token,
    arg_buffer: []Values,

    pub fn init(token_list: []Token, arg_buffer: []Values, allocator: Allocator) Args {
        std.debug.assert(token_list.len > 0);
        return Args{
            .token_list = token_list,
            .allocator = allocator,
            .current_token = &token_list[0],
            .arg_buffer = arg_buffer,
        };
    }

    pub fn deinitArgBuffer(self: *Args) void {
        for (0..self.parsed_args) |i| {
            deinitValues(&self.arg_buffer[i], self.allocator);
        }
    }

    pub fn parse(self: *Args) !void {
        if (self.token_list.len == 0) {
            return;
        }
        if (self.current_token.value != .whitespace) {
            const token = self.current_token;
            self.invalid = genInvalidStatement(
                InvalidReason.ExpectedOther,
                .{
                    .expected = "whitespace",
                    .found = @tagName(token.value),
                    .pos = token.pos,
                    .lexeme = token.lexeme,
                },
                self.allocator,
            );
            return;
        }
        var arg_idx: usize = 0;
        var current_args: *Values = undefined;

        while (self.advance()) {
            const token = self.current_token;
            switch (token.value) {
                .whitespace => {
                    if (arg_idx == self.arg_buffer.len) {
                        self.invalid = genInvalidStatement(
                            .InvalidArgCount,
                            .{
                                .expected = self.arg_buffer.len,
                                .got = arg_idx + 1,
                            },
                            self.allocator,
                        );
                    }

                    self.arg_buffer[arg_idx] = Values.init(self.allocator);
                    current_args = &self.arg_buffer[arg_idx];
                    arg_idx += 1;
                    self.parsed_args = arg_idx;
                },
                inline .literal, .quoted => |v| try current_args.append(Value{ .value = v }),
                .expression => {
                    const expression = try self.parseExpression();
                    try current_args.append(Value{ .expession = expression });
                },
                else => {
                    self.invalid = genInvalidStatement(
                        InvalidReason.ExpectedOther,
                        .{
                            .expected = "space or value",
                            .found = @tagName(token.value),
                            .pos = token.pos,
                            .lexeme = token.lexeme,
                        },
                        self.allocator,
                    );
                },
            }

            if (self.invalid != null) return;
        }
    }

    fn advance(self: *Args) bool {
        if (self.current_idx >= self.token_list.len) return false;

        self.current_token = &self.token_list[self.current_idx];
        self.current_idx += 1;
        return true;
    }

    fn parseExpression(self: *Args) !Expression {
        std.debug.assert(self.current_token.value == .expression and self.current_token.value.expression);

        var expression_level: usize = 1;
        var output = std.ArrayList(*Token).init(self.allocator);
        errdefer output.deinit();
        var op_stack = std.ArrayList(*Token).init(self.allocator);
        defer op_stack.deinit();

        while (self.advance()) {
            const token = self.current_token;
            switch (token.value) {
                .identifiers, .quoted => try output.append(token),
                .operator => |op| {
                    while (op_stack.items.len > 0) {
                        const item = op_stack.items[op_stack.items.len - 1].value;
                        if (item != .operator) break;
                        if (op.order() < item.operator.order()) break;
                        try output.append(op_stack.pop().?);
                    }
                    try op_stack.append(token);
                },
                .expression => |e| if (e) {
                    expression_level += 1;
                    try op_stack.append(token);
                } else {
                    while (op_stack.pop()) |o| {
                        if (o.value == .expression) {
                            break;
                        }
                        try output.append(o);
                    }
                    expression_level -= 1;
                    if (expression_level == 0) {
                        // End of expression
                        break;
                    }
                    if (expression_level < 1) {
                        return error.UnmatchedParenthesis;
                    }
                },
                else => return error.UnexpectedToken,
            }
        }

        while (op_stack.pop()) |o| {
            if (o.value == .expression) {
                if (op_stack.items.len != 0) {
                    return error.UnmatchedParenthesis;
                }
                continue;
            }
            try output.append(o);
        }

        return try output.toOwnedSlice();
    }
};

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
        .InvalidArgCount => "Expected {} arguments, got {}",
    };

    const msg = std.fmt.allocPrint(
        allocator,
        format,
        args,
    ) catch "Not enough memory to store invalid reason.";
    return Statement{ .invalid = msg };
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
        .expession => try expect(true),
    }
}

fn expectValidStatement(stmnt: Statement) !void {
    if (stmnt == .invalid) {
        std.log.err("Unexpected Invalid Statement: {s}", .{stmnt.invalid});
        try expect(false);
    }
}

test parse {
    {
        var noTokens = try TokenList.initCapacity(test_allocator, 0);
        defer noTokens.deinit();

        var statement = try parse(noTokens, test_allocator);
        defer statement.deinit(test_allocator);

        try expect(statement == Statement.nothing);
    }
    {
        var exitExprTokens = try genTestTokenList(&[_]TokenValue{.{ .keyword = Keyword.EXIT }});
        defer tokens.deinitTokenList(&exitExprTokens);

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
        defer tokens.deinitTokenList(&postExprTokens);

        var statement = try parse(postExprTokens, test_allocator);
        defer statement.deinit(test_allocator);

        try expectValidStatement(statement);
        try expectEqualStrings("POST", statement.request.method);
        try expectValueAt(statement.request.value, 0, "http://some_url.com");
    }
    {
        var token_list = try genTestTokenList(&[_]TokenValue{
            .{ .keyword = Keyword.EXIT },
            .{ .whitespace = 1 },
            .{ .literal = "gg" },
        });
        defer tokens.deinitTokenList(&token_list);

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
            .{ .expression = true },
            .{ .identifiers = &[_]String{ "some", "variable" } },
            .{ .expression = false },
            .{ .quoted = "ggg" },
        });
        defer tokens.deinitTokenList(&token_list);

        var statement = try parse(token_list, test_allocator);
        defer statement.deinit(test_allocator);

        try expectValidStatement(statement);
        try expectValueAt(statement.print, 0, "gg");
        try expectValueAt(statement.print, 1, "");
        try expectValueAt(statement.print, 2, "ggg");
    }
    {
        var token_list = try genTestTokenList(&[_]TokenValue{
            .{ .keyword = Keyword.SET },
            .{ .whitespace = 1 },
            .{ .literal = "gg" },
            .{ .whitespace = 1 },
            .{ .expression = true },
            .{ .identifiers = &[_]String{ "some", "variable" } },
            .{ .expression = false },
            .{ .literal = ".literal" },
        });
        defer tokens.deinitTokenList(&token_list);

        var statement = try parse(token_list, test_allocator);
        defer statement.deinit(test_allocator);

        try expectValidStatement(statement);
        try expectValueAt(statement.set.variable, 0, "gg");
        try expectValueAt(statement.set.value, 0, "");
        try expectValueAt(statement.set.value, 1, ".literal");
    }
}

test "parse breaks on command without arg" {
    var token_list = try genTestTokenList(&[_]TokenValue{.{ .keyword = Keyword.PUT }});
    defer tokens.deinitTokenList(&token_list);

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
    defer tokens.deinitTokenList(&token_list);

    var args_buffer: [2]Values = undefined;
    var args = try parseArgs(token_list.items, &args_buffer, test_allocator);
    defer args.deinitArgBuffer();
    defer if (args.invalid) |*i| {
        i.deinit(test_allocator);
    };

    try expect(args.invalid == null);
    if (args.parsed_args != 2) {
        std.log.err("Expected arg count {}, but got {}\n", .{ 2, args.parsed_args });
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

    inline for (cases) |case| {
        var token_list = case;
        defer tokens.deinitTokenList(&token_list);

        var args_buffer: [2]Values = undefined;
        var args = try parseArgs(token_list.items, &args_buffer, test_allocator);
        defer args.deinitArgBuffer();

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

        var vals = [_]Values{};
        var args = Args.init(token_list.items, &vals, test_allocator);
        const expression = try args.parseExpression();
        defer test_allocator.free(expression);

        try expect(expression.len == case.expected.len);
        for (case.expected, expression) |idx, tkn| {
            if (&token_list.items[idx] != tkn) {
                var expr_str = strings.StringBuilder.init(test_allocator);
                defer expr_str.clearAndFree();
                for (token_list.items) |t| {
                    if (expr_str.items.len > 0) {
                        try expr_str.append(' ');
                    }
                    try expr_str.appendSlice(t.lexeme);
                }
                try expr_str.appendSlice(" ->");
                for (expression) |t| {
                    try expr_str.append(' ');
                    try expr_str.appendSlice(t.lexeme);
                }
                std.log.err("{s}", .{expr_str.items});

                try expect(false);
            }
        }
    }
}
