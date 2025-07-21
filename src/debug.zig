const std = @import("std");
const stderr = std.io.getStdErr().writer();

const tokens = @import("tokens.zig");
const strings = @import("strings.zig");
const StringBuilder = strings.StringBuilder;

var active = false;
var elapsed_buf: [32]u8 = undefined;
var timer: ?std.time.Timer = null;

pub fn activate() void {
    active = true;
    timer = std.time.Timer.start() catch null;
    println0("Debug mode active");
}

pub fn isActive() bool {
    return active;
}

fn getElapsedStr() []const u8 {
    const time = std.time;

    if (timer) |*t| {
        const elapsed = t.read();

        const ms = (elapsed / time.ns_per_ms) % time.ms_per_s;
        const seconds = (elapsed / time.ns_per_s) % time.s_per_min;
        const minutes = (elapsed / time.ns_per_min) % 60;
        const hours = (elapsed / time.ns_per_hour);

        return std.fmt.bufPrint(
            &elapsed_buf,
            "[{}:{:0>2}:{:0>2}.{:0>3}] ",
            .{ hours, minutes, seconds, ms },
        ) catch "";
    } else {
        return "";
    }
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (!active)
        return;

    stderr.print("{s}-- " ++ fmt, .{getElapsedStr()} ++ args) catch {};
}

pub fn print0(comptime str: []const u8) void {
    print(str, .{});
}

pub fn println(comptime fmt: []const u8, args: anytype) void {
    if (!active) return;

    print(fmt ++ "\n", args);
}

pub fn println0(comptime str: []const u8) void {
    println(str, .{});
}

pub fn debugTokenList(token_list: tokens.TokenList, allocator: std.mem.Allocator) void {
    if (!active)
        return
    else {
        @branchHint(std.builtin.BranchHint.cold);

        var tokens_str = StringBuilder.init(allocator);
        defer tokens_str.deinit();

        for (token_list.items) |item| {
            if (tokens_str.items.len > 0) {
                tokens_str.appendSlice(", ") catch {};
            }
            tokens_str.appendSlice(@tagName(item.value)) catch {};
        }
        println("Tokens: {s}", .{tokens_str.items});
    }
}
