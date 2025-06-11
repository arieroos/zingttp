const std = @import("std");
const builtin = @import("builtin");

const stdOut = std.io.getStdOut().writer();

fn println(comptime format: []const u8, args: anytype) void {
    stdOut.print(format, args) catch unreachable;
    stdOut.print("\n", .{}) catch unreachable;
}

pub fn main() !void {
    println("Running tests!", .{});

    for (builtin.test_functions) |t| {
        if (std.mem.eql(u8, t.name, "main.test_0")) {
            continue;
        }
        runTest(t);
        println("-----", .{});
    }
}

fn runTest(testFn: std.builtin.TestFn) void {
    println("{s}:", .{testFn.name});
    std.testing.allocator_instance = .{};
    const result = testFn.func();

    if (std.testing.allocator_instance.deinit() == .leak) {
        println("> Memory Leak!", .{});
    }
    if (result) |_| {
        println("> Success", .{});
        return;
    } else |err| {
        println("> Failed: {}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    }
}
