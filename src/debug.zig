const std = @import("std");
const stderr = std.io.getStdErr().writer();

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

pub fn hexdump(comptime str: []const u8, bytes: []const u8) void {
    if (!active) {
        return;
    }

    println0("hexdump of " ++ str ++ ": ");

    var bytes_read: usize = 0;
    var prev_slice: []const u8 = bytes[0..0];
    var repeated = false;
    const hex_width = 32;

    while (bytes_read < bytes.len) {
        const end = @min(bytes_read + hex_width, bytes.len);
        const current_slice = bytes[bytes_read..end];
        bytes_read = end;

        if (std.mem.eql(u8, current_slice, prev_slice)) {
            if (!repeated) {
                stderr.print("*\n", .{}) catch unreachable;
            }
            repeated = true;
            continue;
        }
        repeated = false;

        stderr.print("{x:0>8}  ", .{bytes_read - hex_width}) catch unreachable;

        var printed: [hex_width]u8 = undefined;
        var i: usize = 0;
        for (current_slice) |c| {
            stderr.print("{x:0>2} ", .{c}) catch unreachable;
            if (i % 8 == 7) stderr.print(" ", .{}) catch unreachable;

            if (std.ascii.isControl(c)) {
                printed[i] = '.';
            } else {
                printed[i] = c;
            }
            i += 1;
        }

        stderr.print(" |{s}|\n", .{printed}) catch unreachable;

        prev_slice = current_slice;
    }
    stderr.print("{x:0>8}\n", .{bytes_read}) catch unreachable;
}
