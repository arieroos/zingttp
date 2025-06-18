const std = @import("std");
const builtin = @import("builtin");

const stdOut = std.io.getStdOut().writer();

const AnsiEsc = enum { reset, red, green, yellow };

fn esc(comptime ansi: AnsiEsc) []const u8 {
    return "\x1b[" ++ comptime switch (ansi) {
        .reset => "0",
        .red => "31",
        .green => "32",
        .yellow => "33",
    } ++ "m";
}

fn print(comptime format: []const u8, args: anytype) void {
    stdOut.print(format, args) catch unreachable;
}

fn print_fmt(comptime ansi: AnsiEsc, comptime fmt: []const u8, args: anytype) void {
    print(esc(ansi) ++ fmt ++ esc(AnsiEsc.reset), args);
}

fn println(comptime format: []const u8, args: anytype) void {
    print(format ++ "\n", args);
}

fn println_fmt(comptime ansi: AnsiEsc, comptime fmt: []const u8, args: anytype) void {
    println(esc(ansi) ++ fmt ++ esc(AnsiEsc.reset), args);
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

    inline for ([_]Result{ Result.failure, Result.leaked, Result.success }) |result| {
        const count = results.get(result);
        if (count) |c| {
            const ansi = switch (result) {
                .failure, .leaked => AnsiEsc.red,
                .success => AnsiEsc.green,
            };
            println_fmt(ansi, "{s}: {}/{}", .{ @tagName(result), c, test_cnt });
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
        println_fmt(AnsiEsc.green, "success", .{});
    } else |err| {
        println_fmt(AnsiEsc.red, "failed: {}", .{err});
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
