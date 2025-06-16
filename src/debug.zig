const std = @import("std");
const stderr = std.io.getStdErr().writer();

var active = false;
var elapsed_buf: [32]u8 = undefined;
var timer: ?std.time.Timer = null;

pub fn activate() void {
    active = true;
    timer = std.time.Timer.start() catch null;
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
