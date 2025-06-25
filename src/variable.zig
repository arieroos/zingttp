const std = @import("std");

const Allocator = std.mem.Allocator;
const Pointer = std.builtin.Type.Pointer;

const debug = @import("debug.zig");

const strings = @import("strings.zig");
const String = strings.String;
const StringBuilder = strings.StringBuilder;
const AllocString = strings.AllocString;

pub const VariableList = std.ArrayList(Variable);
pub const VariableMap = std.StringHashMap(?Variable);

pub const Variable = union(enum) {
    const Self = @This();

    boolean: bool,
    int: i128,
    float: f128,
    string: AllocString,
    list: VariableList,
    map: VariableMap,

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

    pub fn initMap(allocator: Allocator) Self {
        return Self{ .map = VariableMap.init(allocator) };
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
            .map => |m| try stringifyMap(m, depth, allocator),
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

    pub fn mapPut(self: *Self, key: String, val: ?Variable, allocator: Allocator) !void {
        switch (self.*) {
            .map => {},
            else => return error.VariableIsNotAMap,
        }

        const owned_key = try strings.toOwned(key, allocator);
        errdefer allocator.free(owned_key);

        const entry = try self.map.getOrPut(owned_key);
        if (entry.found_existing) {
            defer allocator.free(owned_key);
            if (entry.value_ptr.*) |*v| v.deinit();
        }
        entry.value_ptr.* = val;
    }

    pub fn copy(self: Self, allocator: Allocator) !Self {
        return switch (self) {
            .boolean, .int, .float => self,
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
                var n = Variable{ .map = VariableMap.init(allocator) };
                errdefer n.deinit();

                var mi = m.iterator();
                while (mi.next()) |e| {
                    try n.mapPut(e.key_ptr.*, e.value_ptr.*, allocator);
                }
                break :cpy n;
            },
        };
    }

    pub fn deinit(self: *Self) void {
        switch (self.*) {
            .boolean, .int, .float => {},
            .string => |*s| s.deinit(),
            .list => |*l| {
                for (l.items) |*e| {
                    e.deinit();
                }
                l.clearAndFree();
            },
            .map => |*m| {
                var i = m.iterator();
                while (i.next()) |e| {
                    if (e.value_ptr.*) |*v| v.deinit();
                    m.allocator.free(e.key_ptr.*);
                }

                m.deinit();
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

        if (e.value_ptr.*) |v| {
            const str = try v.toStrAllocDepth(depth + 1, allocator);
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

pub fn resolveVariableFromPath(variable: Variable, path: String) ?Variable {
    var spliterator = std.mem.splitScalar(u8, path, '.');

    while (spliterator.peek()) |p| {
        if (p.len > 0) {
            break;
        }
        _ = spliterator.next();
    }

    debug.println("Looking for variable at {s}", .{path});
    if (spliterator.next()) |part| {
        switch (variable) {
            .boolean, .float, .int, .string => return null,
            .list => |l| {
                if (spliterator.peek()) |_| return null;
                const idx = std.fmt.parseInt(usize, part, 10) catch return null;
                return if (idx < l.items.len) l.items[idx] else null;
            },
            .map => |m| return if (m.get(part)) |p|
                if (p) |pr| resolveVariableFromPath(pr, spliterator.rest()) else null
            else
                null,
        }
    } else return variable;
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
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
    var m = Variable{ .map = VariableMap.init(test_alloc) };
    defer m.deinit();

    try m.mapPut("some int", Variable.fromInt(isize, -9), test_alloc);
    try expect(-9 == m.map.get("some int").?.?.int);

    try m.mapPut("nul", null, test_alloc);
    try expect(null == m.map.get("nul").?);
}

test "Variable map deinit" {
    var m = Variable.initMap(test_alloc);
    errdefer m.deinit();

    try m.mapPut("some value", try Variable.fromStr("some value", test_alloc), test_alloc);
    try m.mapPut("some int", Variable.fromInt(isize, -9), test_alloc);
    try m.mapPut("nul", null, test_alloc);

    var subMap = Variable.initMap(test_alloc);
    errdefer subMap.deinit();
    try subMap.mapPutAny(String, "nested", "deinit", test_alloc);

    try m.mapPut("sub", subMap, test_alloc);

    m.deinit();
    try expect(!std.testing.allocator_instance.detectLeaks());
}
