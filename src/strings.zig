const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;

const Allocator = mem.Allocator;

pub const String = []const u8;
pub const StringBuilder = std.ArrayList(u8);

pub const AllocString = struct {
    allocator: Allocator,
    value: String,

    pub fn init(val: String, allocator: Allocator) !AllocString {
        return AllocString{
            .allocator = allocator,
            .value = try toOwned(val, allocator),
        };
    }

    pub fn deinit(self: *AllocString) void {
        self.allocator.free(self.value);
    }
};

pub const alphabet_lower = init: {
    var init_value: [26]u8 = undefined;
    for (&init_value, 0..) |*a, i| {
        a.* = @as(u8, i) + 'a';
    }
    break :init init_value;
};

pub const alphabet_upper = init: {
    var init_value: [26]u8 = undefined;
    for (&init_value, 0..) |*a, i| {
        a.* = @as(u8, i) + 'A';
    }
    break :init init_value;
};

pub const digits = "0123456789";
pub const alphabet = alphabet_lower ++ alphabet_upper;
pub const alphanumeric = alphabet ++ digits;

pub fn eql(str1: String, str2: String) bool {
    return mem.eql(u8, str1, str2);
}

pub fn iEql(str1: String, str2: String) bool {
    if (str1.len != str2.len) {
        return false;
    }

    for (str1, str2) |c1, c2| {
        if (ascii.toLower(c1) != ascii.toLower(c2)) {
            return false;
        }
    }
    return true;
}

pub fn lstHas(haystack: []const String, needle: String) bool {
    for (haystack) |c| {
        if (eql(needle, c)) {
            return true;
        }
    }
    return false;
}

pub fn iLstHas(haystack: []const String, needle: String) bool {
    for (haystack) |c| {
        if (iEql(needle, c)) {
            return true;
        }
    }
    return false;
}

pub fn startsWith(haystack: String, needle: String) bool {
    return mem.startsWith(u8, haystack, needle);
}

pub fn endsWith(haystack: String, needle: String) bool {
    return mem.endsWith(u8, haystack, needle);
}

pub fn containsAny(haystack: String, needles: String) bool {
    if (haystack.len == 0) {
        return false;
    }

    for (needles) |needle| {
        if (mem.containsAtLeastScalar(u8, haystack, 1, needle)) return true;
    }
    return false;
}

pub fn containsOnly(haystack: String, needles: String) bool {
    if (needles.len == 0) {
        return haystack.len == 0;
    }

    for (haystack) |c| {
        if (!mem.containsAtLeastScalar(u8, needles, 1, c)) return false;
    }
    return true;
}

pub fn indexOfScalar(haystack: String, needle: u8) ?usize {
    return mem.indexOfScalar(u8, haystack, needle);
}

pub fn toOwned(val: String, allocator: Allocator) Allocator.Error!String {
    const allocated = try allocator.alloc(u8, val.len);
    mem.copyForwards(u8, allocated, val);
    return allocated;
}

pub fn trimWhitespace(val: String) String {
    return mem.trim(u8, val, &ascii.whitespace);
}

const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;
const test_alloc = std.testing.allocator;

test AllocString {
    const test_str = "Some test string";

    var control: String = test_str[0..];
    var result_str: ?AllocString = null;

    {
        const copied = try std.fmt.allocPrint(test_alloc, "{s}", .{test_str});
        defer test_alloc.free(copied);

        result_str = try AllocString.init(copied, test_alloc);
        control = copied;
    }
    errdefer result_str.?.deinit();

    try expectEqualStrings(test_str, result_str.?.value);
    if (eql(control, result_str.?.value)) {
        std.log.err("control string not cleared", .{});
        try expect(false);
    }

    result_str.?.deinit();
    try expect(!std.testing.allocator_instance.detectLeaks());
}

test alphabet_lower {
    try expect(alphabet_lower.len == 26);
    for (alphabet_lower) |a| {
        try expect(ascii.isAlphabetic(a) and ascii.isLower(a));
    }
}

test alphabet_upper {
    try expect(alphabet_upper.len == 26);
    for (alphabet_upper) |a| {
        try expect(ascii.isAlphabetic(a) and ascii.isUpper(a));
    }
}

test eql {
    try expect(eql("", ""));
    try expect(!eql("", "test"));
    try expect(!eql("a test", ""));

    try expect(eql("test", "test"));
    try expect(!eql("test", "test1"));

    try expect(!eql("test", "Test"));
    try expect(!eql("test", "Test1"));
}

test iEql {
    try expect(iEql("", ""));
    try expect(!iEql("", "test"));
    try expect(!iEql("a test", ""));

    try expect(iEql("test", "test"));
    try expect(!iEql("test", "test1"));

    try expect(iEql("test", "Test"));
    try expect(!iEql("test", "Test1"));
}

test lstHas {
    const lst = &[_]String{ "", "test" };

    try expect(lstHas(lst, ""));

    try expect(lstHas(lst, "test"));
    try expect(!lstHas(lst, "test1"));

    try expect(!lstHas(lst, "Test"));
    try expect(!lstHas(lst, "Test1"));
}

test iLstHas {
    const lst = &[_]String{ "", "test" };

    try expect(iLstHas(lst, ""));

    try expect(iLstHas(lst, "test"));
    try expect(!iLstHas(lst, "test1"));

    try expect(iLstHas(lst, "Test"));
    try expect(!iLstHas(lst, "Test1"));
}

test startsWith {
    try expect(startsWith("", ""));
    try expect(!startsWith("", "test"));
    try expect(startsWith("a test", ""));

    try expect(startsWith("test something", "test"));
    try expect(!startsWith("test something", "test1"));

    try expect(!startsWith("test something", "Test"));
    try expect(!startsWith("test something", "Test1"));
}

test endsWith {
    try expect(endsWith("", ""));
    try expect(!endsWith("", "test"));
    try expect(endsWith("a test", ""));

    try expect(endsWith("a test", "test"));
    try expect(!endsWith("a test", "test1"));

    try expect(!endsWith("a test", "Test"));
    try expect(!endsWith("a test something", "Test1"));
}

test containsAny {
    try expect(!containsAny("", ""));
    try expect(!containsAny("", "test"));
    try expect(!containsAny("a test", ""));

    try expect(containsAny("a test", "test"));
    try expect(!containsAny("a test", "fghl"));

    try expect(!containsAny("a test", "TEST"));
    try expect(!containsAny("a test something", "FGHL"));
}

test containsOnly {
    try expect(containsOnly("", ""));
    try expect(containsOnly("", "test"));
    try expect(!containsOnly("a test", ""));

    try expect(containsOnly("a test", "a tes"));
    try expect(!containsOnly("a test", "test"));

    try expect(!containsOnly("a test", "A TES"));
    try expect(!containsOnly("a test something", "FGHL"));
}

test toOwned {
    const test_str = "Some test";

    for (&[_]bool{ true, false }) |owned| {
        var result_str: []const u8 = "";
        {
            const copied = try std.fmt.allocPrint(test_alloc, "{s}", .{test_str});
            defer test_alloc.free(copied);

            result_str = if (owned) try toOwned(copied, test_alloc) else copied;
        }

        if (owned) {
            try expectEqualStrings(test_str, result_str);
            test_alloc.free(result_str);
        } else try expect(!std.testing.allocator_instance.detectLeaks());
    }
}

test trimWhitespace {
    try expectEqualStrings("a", trimWhitespace("a"));
    try expectEqualStrings("a", trimWhitespace(" a "));
    try expectEqualStrings("a", trimWhitespace("\na\r"));
    try expectEqualStrings("a", trimWhitespace("a  \t \n"));
    try expectEqualStrings("", trimWhitespace("\n\n  \t"));
    try expectEqualStrings("a", trimWhitespace("\ta"));
}
