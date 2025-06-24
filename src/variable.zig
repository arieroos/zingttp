const std = @import("std");

const Allocator = std.mem.Allocator;

const strings = @import("strings.zig");
const String = strings.String;
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

    pub fn fromStr(str: String, allocator: Allocator) !Self {
        const owned = try AllocString.init(str, allocator);
        return Self{ .string = owned };
    }

    pub fn toStrAlloc(self: *Self, allocator: Allocator) !String {
        return switch (self.*) {
            .string => |s| strings.toOwned(s.value, allocator),
            inline .boolean, .int, .float => |x| std.fmt.allocPrint(allocator, "{}", .{x}),
            else => |t| std.fmt.allocPrint(allocator, "TODO: stringify {s}", .{
                @typeName(@TypeOf(t)),
            }),
        };
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
        const test_str = "testing 123";
        var v = try Variable.fromStr(test_str, test_alloc);
        defer v.deinit();
        try expectEqualStrings(test_str, v.string.value);

        const str = try v.toStrAlloc(test_alloc);
        defer test_alloc.free(str);
        try expectEqualStrings(test_str, str);
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
    var m = Variable{ .map = VariableMap.init(test_alloc) };
    errdefer m.deinit();

    try m.mapPut("some value", try Variable.fromStr("some value", test_alloc), test_alloc);
    try m.mapPut("some int", Variable.fromInt(isize, -9), test_alloc);
    try m.mapPut("nul", null, test_alloc);

    m.deinit();
    try expect(!std.testing.allocator_instance.detectLeaks());
}
