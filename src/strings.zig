const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;

pub const String = []const u8;
pub const StringBuilder = std.ArrayList(u8);

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

pub fn starts_with(haystack: String, needle: String) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

const expect = std.testing.expect;

test eql {
    try expect(eql("", ""));

    try expect(eql("test", "test"));
    try expect(!eql("test", "test1"));

    try expect(!eql("test", "Test"));
    try expect(!eql("test", "Test1"));
}

test iEql {
    try expect(iEql("", ""));

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
