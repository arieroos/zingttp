const std = @import("std");
const Allocator = std.mem.Allocator;

const strings = @import("strings.zig");
const String = strings.String;

pub const Keyword = enum(u8) {
    EXIT,
    SET,
    PRINT,
    WAIT,
    ERROR,
    REQUEST,
    // Flow Control
    DO,
    UNTIL,
    WHILE,
    FOR,
    IF,
    ELSE,
    FUN,
    // HTTP methods
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,
    PATCH,
    // Asserts
    ASSERT,
    ASSERT_SUCCESS,
    ASSERT_REDIRECT,
    ASSERT_FAILED,
    ASSERT_RANGE,
    ASSERT_CODE,
    ASSERT_CONTAINS,
    ASSERT_ERROR,
    // File Ops
    SCRIPT,
    IMPORT,
    EXPORT,
    APPEND,
    REPORT,
};

const operators: *const [12]u8 = "^*/%+-=<>!&|";

pub const Operator = enum(u8) {
    exponent = 0,
    multiply = 1,
    divide = 2,
    modulo = 3,
    plus = 4,
    minus = 5,
    equal = 6,
    greater = 7,
    less = 8,
    not = 9,
    @"and" = 10,
    @"or" = 11,

    pub fn isOp(c: u8) bool {
        return std.mem.containsAtLeastScalar(u8, operators, 1, c);
    }

    pub fn toOp(c: u8) Operator {
        std.debug.assert(isOp(c));

        return @enumFromInt(strings.indexOfScalar(operators, c));
    }

    pub fn toString(self: Operator) String {
        const idx = @intFromEnum(self);
        return operators[idx .. idx + 1];
    }

    pub fn order(self: Operator) u8 {
        const i_self = @intFromEnum(self);
        return switch (i_self) {
            @intFromEnum(Operator.exponent) => 0,
            @intFromEnum(Operator.multiply)...@intFromEnum(Operator.modulo) => 1,
            @intFromEnum(Operator.plus)...@intFromEnum(Operator.minus) => 2,
            @intFromEnum(Operator.equal)...@intFromEnum(Operator.less) => 3,
            @intFromEnum(Operator.not) => 4,
            @intFromEnum(Operator.@"and") => 5,
            @intFromEnum(Operator.@"or") => 6,
            else => unreachable,
        };
    }
};

pub const TokenValue = union(enum) {
    keyword: Keyword,
    literal: String,
    quoted: String,
    identifiers: []const String,
    operator: u8,

    whitespace: usize,
    expression: bool,
    subroutine: bool,

    invalid: String,
};

pub const Token = struct {
    value: TokenValue,
    lexeme: String,
    pos: usize,
    line: usize,
    allocator: Allocator,

    pub fn deinit(self: *Token) void {
        switch (self.value) {
            .identifiers => |i| self.allocator.free(i),
            else => {},
        }
        self.allocator.free(self.lexeme);
    }
};

pub const TokenList = std.ArrayList(Token);

pub fn deinitTokenList(token_list: *TokenList) void {
    for (token_list.items) |*i| {
        i.deinit();
    }
    token_list.deinit();
}

test {
    try std.testing.expect(Operator.exponent.order() < Operator.@"or".order());
}
