const std = @import("std");
const builtin = @import("builtin");

const stdOut = std.io.getStdOut().writer();

fn print(comptime format: []const u8, args: anytype) void {
    stdOut.print(format, args) catch unreachable;
}

fn println(comptime format: []const u8, args: anytype) void {
    print(format, args);
    stdOut.print("\n", .{}) catch unreachable;
}

const Result = enum {
    success,
    failure,
    leaked,
};

pub fn main() !void {
    println("Running tests!", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var results = std.AutoHashMap(Result, usize).init(gpa.allocator());
    defer results.clearAndFree();

    const test_cnt = builtin.test_functions.len - 1;

    var timer = try std.time.Timer.start();
    for (builtin.test_functions) |t| {
        if (std.mem.eql(u8, t.name, "main.test_0")) {
            continue;
        }
        const result = runTest(t);

        const resultCnt = results.get(result) orelse 0;
        try results.put(result, resultCnt + 1);
    }
    const elapsed = timer.read();

    for ([_]Result{ Result.failure, Result.leaked, Result.success }) |result| {
        const count = results.get(result);
        if (count) |c| {
            println("{s}: {}/{}", .{ @tagName(result), c, test_cnt });
        }
    }
    println("Total duartion: {}", .{std.fmt.fmtDuration(elapsed)});
}

fn runTest(testFn: std.builtin.TestFn) Result {
    print("> {s} ", .{testFn.name});
    std.testing.allocator_instance = .{};

    var timer = std.time.Timer.start() catch unreachable;
    const result = testFn.func();
    const elapsed = timer.read();

    print("({}): ", .{std.fmt.fmtDuration(elapsed)});
    if (result) |_| {
        println("success", .{});
    } else |err| {
        println("failed: {}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        println("\n============================================================================\n", .{});
    }

    return if (std.testing.allocator_instance.deinit() == .leak)
        Result.leaked
    else if (result) |_|
        Result.success
    else |_|
        Result.failure;
}
