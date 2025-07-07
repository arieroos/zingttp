const std = @import("std");

const Allocator = std.mem.Allocator;
const Pointer = std.builtin.Type.Pointer;

const debug = @import("debug.zig");

const strings = @import("strings.zig");
const String = strings.String;
const StringBuilder = strings.StringBuilder;
const AllocString = strings.AllocString;

pub const VariableList = std.ArrayList(Variable);
pub const VariableMap = std.StringHashMap(Variable);

pub const Variable = union(enum) {
    const Self = @This();

    null: void,
    boolean: bool,
    int: i128,
    float: f128,
    string: AllocString,
    list: VariableList,
    map: *VariableMap,

    pub fn init(comptime T: type, val: T, allocator: Allocator) !Self {
        const type_info = @typeInfo(T);
        return switch (type_info) {
            .bool => Self.fromBool(val),
            .int => Self.fromInt(T, val),
            .float => Self.fromFloat(T, val),
            .pointer => |p| if (p.child == u8 and p.size == Pointer.Size.slice)
                try Self.fromStr(val, allocator)
            else
                @compileError(
                    @tagName(p.size) ++ " sized " ++ @typeName(p.child) ++ " pointers can't be converted to Variables",
                ),
            .@"enum" => |e| Self.fromInt(e.tag_type, @intFromEnum(val)),
            else => @compileError(
                @typeName(T) ++ "(" ++ @tagName(type_info) ++ ")" ++ " can't be turned into a Variable",
            ),
        };
    }

    pub fn initMap(allocator: Allocator) !Self {
        const m = try allocator.create(VariableMap);
        m.* = VariableMap.init(allocator);
        return Self{ .map = m };
    }

    pub fn fromBool(val: bool) Self {
        return Self{ .boolean = val };
    }

    pub fn fromInt(comptime T: type, val: T) Self {
        switch (@typeInfo(T)) {
            .int => {},
            else => @compileError(@typeName(T) ++ " is not an integer type"),
        }

        return Self{ .int = val };
    }

    pub fn fromFloat(comptime T: type, val: T) Self {
        switch (@typeInfo(T)) {
            .float => {},
            else => @compileError(@typeName(T) ++ " is not a float type"),
        }

        return Self{ .float = val };
    }

    pub fn fromStr(str: String, allocator: Allocator) !Self {
        const owned = try AllocString.init(str, allocator);
        return Self{ .string = owned };
    }

    pub fn fromArrayList(
        comptime T: type,
        list: std.ArrayList(T),
        allocator: Allocator,
    ) !Self {
        var list_self = try VariableList.initCapacity(allocator, list.items.len);
        for (list.items) |item| {
            list_self.appendAssumeCapacity(try Self.init(T, item, allocator));
        }

        return Self{ .list = list_self };
    }

    pub fn toStrAlloc(self: Self, allocator: Allocator) !String {
        return self.toStrAllocDepth(0, allocator);
    }

    pub fn toStrAllocDepth(self: Self, depth: usize, allocator: Allocator) !String {
        return switch (self) {
            .null => strings.toOwned("", allocator),
            inline .boolean, .int => |x| std.fmt.allocPrint(allocator, "{}", .{x}),
            .float => |f| blk: {
                const abs = @abs(f);
                break :blk if (abs >= 1e-3 and abs <= 1e6)
                    std.fmt.allocPrint(allocator, "{d}", .{f})
                else
                    std.fmt.allocPrint(allocator, "{e}", .{f});
            },
            .string => |s| strings.toOwned(s.value, allocator),
            .list => |l| try stringifyList(l, depth, allocator),
            .map => |m| try stringifyMap(m.*, depth, allocator),
        };
    }

    pub fn mapPutAny(
        self: *Self,
        comptime T: type,
        key: String,
        val: T,
        allocator: Allocator,
    ) !void {
        const v = try Self.init(T, val, allocator);
        try self.mapPut(key, v, allocator);
    }

    pub fn mapPut(self: *Self, key: String, val: Variable, allocator: Allocator) !void {
        std.debug.assert(self.* == .map);

        const owned_key = try strings.toOwned(key, allocator);
        errdefer allocator.free(owned_key);

        const entry = try self.map.getOrPut(owned_key);
        if (entry.found_existing) {
            allocator.free(owned_key);
            entry.value_ptr.deinit();
        }
        entry.value_ptr.* = val;
    }

    pub fn mapGet(self: Self, key: String) ?Variable {
        std.debug.assert(self == .map);

        return if (self.map.get(key)) |v| v else null;
    }

    pub fn copy(self: Self, allocator: Allocator) !Self {
        return switch (self) {
            .null, .boolean, .int, .float => self,
            .string => |s| Self.fromStr(s.value, allocator),
            .list => |l| cpy: {
                var n = try VariableList.initCapacity(allocator, l.items.len);
                errdefer n.clearAndFree();

                for (l.items) |item| {
                    try n.append(try item.copy(allocator));
                }
                break :cpy Variable{ .list = n };
            },
            .map => |m| cpy: {
                var n = try Variable.initMap(allocator);
                errdefer n.deinit();

                var mi = m.iterator();
                while (mi.next()) |e| {
                    const new_value = try e.value_ptr.copy(allocator);
                    try n.mapPut(e.key_ptr.*, new_value, allocator);
                }
                break :cpy n;
            },
        };
    }

    pub fn deinit(self: *Self) void {
        switch (self.*) {
            .null, .boolean, .int, .float => {},
            .string => |*s| s.deinit(),
            .list => |*l| {
                for (l.items) |*e| {
                    e.deinit();
                }
                l.clearAndFree();
            },
            .map => |m| {
                var i = m.iterator();
                while (i.next()) |e| {
                    e.value_ptr.*.deinit();
                    m.allocator.free(e.key_ptr.*);
                }

                m.clearAndFree();
                m.allocator.destroy(m);
            },
        }
    }
};

fn stringifyList(l: VariableList, depth: usize, allocator: Allocator) Allocator.Error!String {
    if (l.items.len == 0) {
        return try strings.toOwned("[]", allocator);
    }

    var builder = StringBuilder.init(allocator);
    defer builder.clearAndFree();

    try builder.appendSlice("[\n\t");
    for (l.items[0 .. l.items.len - 1]) |item| {
        for (0..depth) |_| {
            try builder.append('\t');
        }

        const str = try item.toStrAllocDepth(depth + 1, allocator);
        defer allocator.free(str);

        try builder.appendSlice(str);
        try builder.appendSlice(",\n\t");
    }
    for (0..depth) |_| {
        try builder.append('\t');
    }
    const lastItem = l.items[l.items.len - 1];
    const str = try lastItem.toStrAllocDepth(depth + 1, allocator);
    defer allocator.free(str);

    try builder.appendSlice(str);
    try builder.append('\n');
    for (0..depth) |_| {
        try builder.append('\t');
    }
    try builder.append(']');

    return builder.toOwnedSlice();
}

fn stringifyMap(m: VariableMap, depth: usize, allocator: Allocator) Allocator.Error!String {
    const count = m.count();
    if (count == 0) {
        return try strings.toOwned("{}", allocator);
    }

    var builder = StringBuilder.init(allocator);
    defer builder.clearAndFree();

    try builder.appendSlice("{\n\t");

    var it = m.iterator();
    var idx: usize = 1;
    while (it.next()) |e| : (idx += 1) {
        for (0..depth) |_| {
            try builder.append('\t');
        }

        try builder.appendSlice(e.key_ptr.*);
        try builder.appendSlice(": ");

        if (e.value_ptr.* != Variable.null) {
            const str = try e.value_ptr.toStrAllocDepth(depth + 1, allocator);
            defer allocator.free(str);

            try builder.appendSlice(str);
        } else try builder.appendSlice("NULL");

        try builder.appendSlice(if (idx < count) ",\n\t" else "\n");
    }
    for (0..depth) |_| {
        try builder.append('\t');
    }
    try builder.append('}');

    return builder.toOwnedSlice();
}

pub fn resolveVariableFromPath(variable: Variable, path: String) Variable {
    var spliterator = std.mem.splitScalar(u8, path, '.');

    while (spliterator.peek()) |p| {
        if (p.len > 0) {
            break;
        }
        _ = spliterator.next();
    }

    if (spliterator.next()) |part| {
        debug.println("Looking up variable {s}", .{path});
        switch (variable) {
            .boolean, .float, .int, .string, .null => return .null,
            .list => |l| {
                if (spliterator.peek()) |_| return .null;
                const idx = std.fmt.parseInt(usize, part, 10) catch return .null;
                return if (idx < l.items.len) l.items[idx] else .null;
            },
            .map => |m| return if (m.get(part)) |pr|
                resolveVariableFromPath(pr, spliterator.rest())
            else
                .null,
        }
    } else return variable;
}

pub fn parseVariable(str: String, allocator: Allocator) !Variable {
    if (str.len == 0) {
        return .null;
    }

    if (strings.iEql(str, "null")) {
        return .null;
    }
    if (strings.iEql(str, "false")) {
        return Variable.fromBool(false);
    }
    if (strings.iEql(str, "true")) {
        return Variable.fromBool(true);
    }
    if (std.fmt.parseInt(i128, str, 0)) |v| {
        return Variable.fromInt(i128, v);
    } else |_| {}
    if (std.fmt.parseFloat(f128, str)) |v| {
        return Variable.fromFloat(f128, v);
    } else |_| {}

    if (str.len > 1 and str[0] == str[str.len - 1]) {
        const trimmed_str = if (str[0] == '\'' or str[0] == '"') str[1 .. str.len - 1] else str;
        return try Variable.fromStr(trimmed_str, allocator);
    }
    return try Variable.fromStr(str, allocator);
}

pub fn buildMap(keys: String, val: Variable, allocator: Allocator) !Variable {
    var spliterator = std.mem.splitBackwardsScalar(u8, keys, '.');

    var result_var = try val.copy(allocator);
    errdefer result_var.deinit();

    while (spliterator.next()) |key_part| {
        if (key_part.len == 0) return error.InvalidKey;

        var new_map = try Variable.initMap(allocator);
        try new_map.mapPut(key_part, result_var, allocator);
        result_var = new_map;
    }
    return result_var;
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
fn expectApproxEqRel(expected: f128, actual: f128) !void {
    const tolerance = std.math.floatEps(f128);
    return std.testing.expectApproxEqRel(expected, actual, tolerance);
}
const test_alloc = std.testing.allocator;

test Variable {
    {
        var v = Variable.fromBool(true);
        defer v.deinit();
        try expect(v.boolean);

        const str = try v.toStrAlloc(test_alloc);
        defer test_alloc.free(str);
        try expectEqualStrings("true", str);
    }
    {
        var v = Variable.fromInt(usize, 7856);
        defer v.deinit();
        try expect(v.int == 7856);

        const str = try v.toStrAlloc(test_alloc);
        defer test_alloc.free(str);
        try expectEqualStrings("7856", str);
    }
    {
        var v = Variable.fromFloat(f32, -0.625);
        defer v.deinit();
        try expect(v.float == -0.625);

        const str = try v.toStrAlloc(test_alloc);
        defer test_alloc.free(str);
        try expectEqualStrings("-0.625", str);
    }
    {
        const test_str = "testing 123";
        var v = try Variable.fromStr(test_str, test_alloc);
        defer v.deinit();
        try expectEqualStrings(test_str, v.string.value);

        const str = try v.toStrAlloc(test_alloc);
        defer test_alloc.free(str);
        try expectEqualStrings(test_str, str);
    }
    {
        const test_strs = &[_]String{ "testing 123", "more values", "test a bit" };
        var test_list = try std.ArrayList(String).initCapacity(test_alloc, test_strs.len);
        defer test_list.clearAndFree();
        test_list.appendSliceAssumeCapacity(test_strs);

        var v = try Variable.fromArrayList(String, test_list, test_alloc);
        defer v.deinit();
        for (v.list.items, 0..) |item, i| {
            try expectEqualStrings(test_strs[i], item.string.value);
        }

        try v.list.append(Variable.fromBool(true));
        try v.list.append(Variable.fromInt(u16, 567));
        try v.list.append(Variable.fromFloat(f32, 1.375));

        const str = try v.toStrAlloc(test_alloc);
        defer test_alloc.free(str);
        try expectEqualStrings(
            "[\n\ttesting 123,\n\tmore values,\n\ttest a bit,\n\ttrue,\n\t567,\n\t1.375\n]",
            str,
        );
    }
}

test "Variable map put" {
    var m = try Variable.initMap(test_alloc);
    defer m.deinit();

    try m.mapPut("some int", Variable.fromInt(isize, -9), test_alloc);
    try expect(-9 == m.mapGet("some int").?.int);

    try m.mapPut("nul", Variable.null, test_alloc);
    try expect(Variable.null == m.mapGet("nul").?);
}

test "Variable map deinit" {
    var m = try Variable.initMap(test_alloc);
    errdefer m.deinit();

    try m.mapPut("some value", try Variable.fromStr("some value", test_alloc), test_alloc);
    try m.mapPut("some int", Variable.fromInt(isize, -9), test_alloc);
    try m.mapPut("nul", Variable.null, test_alloc);

    var subMap = try Variable.initMap(test_alloc);
    errdefer subMap.deinit();
    try subMap.mapPutAny(String, "nested", "deinit", test_alloc);

    try m.mapPut("sub", subMap, test_alloc);

    m.deinit();
    try expect(!std.testing.allocator_instance.detectLeaks());
}

test "Variable map copy" {
    var m1 = try Variable.initMap(test_alloc);
    errdefer m1.deinit();

    try m1.mapPut("some value", try Variable.fromStr("some value", test_alloc), test_alloc);
    try m1.mapPut("some int", Variable.fromInt(isize, -9), test_alloc);
    try m1.mapPut("keep_me", Variable.fromInt(isize, 16), test_alloc);
    try m1.mapPut("nul", Variable.null, test_alloc);

    var m2 = try m1.copy(test_alloc);
    defer m2.deinit();

    try m2.mapPut("some int", Variable.fromInt(u8, 128), test_alloc);
    try expect(m1.mapGet("some int").?.int == -9);
    try expect(m2.mapGet("some int").?.int == 128);

    m1.deinit();
    try expect(m2.mapGet("keep_me").?.int == 16);
}

test "stringifyMap" {
    var m = try Variable.initMap(test_alloc);
    defer m.deinit();

    try m.mapPut("v1", Variable.fromInt(u8, 22), test_alloc);
    try m.mapPut("v2", Variable.fromInt(u8, 22), test_alloc);

    var inner = try Variable.initMap(test_alloc);
    try inner.mapPut("str", try Variable.fromStr("44xy", test_alloc), test_alloc);
    try m.mapPut("inner", inner, test_alloc);

    const to_str = try m.toStrAlloc(test_alloc);
    defer test_alloc.free(to_str);

    try expect(std.mem.containsAtLeast(u8, to_str, 1, "\tinner: {"));
}

test parseVariable {
    var str0x5 = try Variable.fromStr("0x5", test_alloc);
    var str0o10 = try Variable.fromStr("0o10", test_alloc);
    var normal = try Variable.fromStr("Just a normal string", test_alloc);
    var palindrome = try Variable.fromStr("amanaplanacanalpanama", test_alloc);
    defer str0x5.deinit();
    defer str0o10.deinit();
    defer normal.deinit();
    defer palindrome.deinit();

    const cases = &[_]struct {
        input: String,
        expected: Variable,
    }{
        .{ .input = "", .expected = .null },
        .{ .input = "true", .expected = Variable.fromBool(true) },
        .{ .input = "FALSE", .expected = Variable.fromBool(false) },
        .{ .input = "5", .expected = Variable.fromInt(u8, 5) },
        .{ .input = "-5", .expected = Variable.fromInt(i8, -5) },
        .{ .input = "0x5", .expected = Variable.fromInt(u8, 5) },
        .{ .input = "0o10", .expected = Variable.fromInt(u8, 8) },
        .{ .input = "3.6", .expected = Variable.fromFloat(f128, 3.6) },
        .{ .input = "3e-6", .expected = Variable.fromFloat(f128, 3e-6) },
        .{ .input = "'0x5'", .expected = str0x5 },
        .{ .input = "\"0o10\"", .expected = str0o10 },
        .{ .input = "Just a normal string", .expected = normal },
        .{ .input = "'Just a normal string'", .expected = normal },
        .{ .input = "amanaplanacanalpanama", .expected = palindrome },
    };

    inline for (cases) |case| {
        var parsed = try parseVariable(case.input, test_alloc);
        defer parsed.deinit();

        switch (case.expected) {
            .null => try expect(parsed == .null),
            .boolean => |ob| {
                if (parsed != .boolean) {
                    std.log.err(
                        "\"{s}\" did not parse to boolean, but to {s}",
                        .{ case.input, @tagName(parsed) },
                    );
                    try expect(false);
                }
                try expect(ob == parsed.boolean);
            },
            .int => |oi| {
                if (parsed != .int) {
                    std.log.err(
                        "\"{s}\" did not parse to int, but to {s}",
                        .{ case.input, @tagName(parsed) },
                    );
                    try expect(false);
                }
                try expect(oi == parsed.int);
            },
            .float => |of| {
                if (parsed != .float) {
                    std.log.err(
                        "\"{s}\" did not parse to float, but to {s}",
                        .{ case.input, @tagName(parsed) },
                    );
                    try expect(false);
                }
                try expectApproxEqRel(of, parsed.float);
            },
            .string => |os| {
                if (parsed != .string) {
                    std.log.err(
                        "\"{s}\" did not parse to string, but to {s}",
                        .{ case.input, @tagName(parsed) },
                    );
                    try expect(false);
                }
                try expectEqualStrings(os.value, parsed.string.value);
            },
            else => {
                std.log.err(
                    "parseVariable does not support {s}",
                    .{@tagName(case.expected)},
                );
            },
        }
    }
}

test buildMap {
    var m1 = try buildMap("a", Variable.fromInt(u8, 1), test_alloc);
    defer m1.deinit();
    try expect(m1.mapGet("a").?.int == 1);

    var m2 = try buildMap("a.b", Variable.fromInt(u8, 1), test_alloc);
    defer m2.deinit();
    try expect(m2.mapGet("a").? == .map);
    try expect(m2.mapGet("a").?.mapGet("b").?.int == 1);

    var e = buildMap("a.b..c", Variable.fromInt(u8, 1), test_alloc);
    errdefer if (e) |*v| v.deinit() else |_| {};
    try std.testing.expectError(error.InvalidKey, e);
}
