const std = @import("std");
const build = @import("build");

const strings = @import("strings.zig");
const String = strings.String;
const AllocString = strings.AllocString;

const debug = @import("debug.zig");

const runner = @import("runner.zig");
const repl = @import("repl.zig");
const file = @import("file.zig");

const RunType = union(enum) {
    repl: void,
    file: AllocString,
    version: void,

    fn deinit(self: *RunType) void {
        switch (self.*) {
            .file => |*f| f.deinit(),
            else => {},
        }
    }
};

const Args = struct {
    run_type: RunType,
    debug_mode: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var args = try readAndParseArgs(gpa.allocator());
    if (args.debug_mode) {
        debug.activate();
    }
    defer args.run_type.deinit();

    var ui: ?runner.UserInterface = null;
    switch (args.run_type) {
        .version => {
            try std.io.getStdOut().writer().print("ZingTTP {s}\n", .{build.manifest.version});
            debug.println0("Exiting");
            return;
        },
        .file => |f| ui =
            runner.UserInterface{ .file = file.InitStdFile(runner.line_size, f.value, gpa.allocator()) },
        .repl => ui =
            runner.UserInterface{ .repl = try repl.InitStdRepl() },
    }

    try runner.run(&ui.?, gpa.allocator());
}

fn readAndParseArgs(allocator: std.mem.Allocator) !Args {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var args = try std.process.ArgIterator.initWithAllocator(arena.allocator());
    var arg_list = std.ArrayList(String).init(arena.allocator());

    _ = args.skip(); // Discard program name
    while (args.next()) |arg| {
        try arg_list.append(arg);
    }

    return try parseArgs(arg_list, allocator);
}

fn parseArgs(arg_list: std.ArrayList(String), allocator: std.mem.Allocator) !Args {
    const args = arg_list.items;
    if (args.len == 0) {
        return Args{ .run_type = RunType.repl };
    }

    const version_args = &[_]String{ "-v", "--version" };
    const debug_args = &[_]String{ "-d", "--debug" };
    var arg_struct = Args{ .run_type = RunType.repl };

    for (args) |arg| {
        if (arg.len == 0) {
            continue;
        }

        if (strings.iLstHas(debug_args, arg)) {
            arg_struct.debug_mode = true;
            continue;
        }

        if (strings.iLstHas(version_args, arg)) {
            arg_struct.run_type = RunType.version;
            continue;
        }

        if (!strings.startsWith(arg, "-")) {
            arg_struct.run_type = .{ .file = try AllocString.init(arg, allocator) };
        }
    }

    return arg_struct;
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

const test_alloc = std.testing.allocator;

test {
    debug.activate();
    std.testing.refAllDecls(@This());
}

fn toArgList(a: []const String) !std.ArrayList(String) {
    var l = try std.ArrayList(String).initCapacity(test_alloc, a.len);
    l.appendSliceAssumeCapacity(a);
    return l;
}

test "parseArgs parses version arg" {
    const test_cases = &[_]String{ "-v", "-V", "--version", "--Version" };
    for (test_cases) |test_arg| {
        var test_args = try toArgList(&[_]String{test_arg});
        defer test_args.clearAndFree();

        const args = try parseArgs(test_args, test_alloc);
        try expect(args.run_type == RunType.version);
    }

    const negatives = &[_]String{ "-d", "-F", "--fersion", "" };
    for (negatives) |test_arg| {
        var test_args = try toArgList(&[_]String{test_arg});
        defer test_args.clearAndFree();

        var args = try parseArgs(test_args, test_alloc);
        defer args.run_type.deinit();

        try expect(args.run_type != RunType.version);
    }
}

test "parseArgs parses debug arg" {
    const test_cases = &[_]String{ "-d", "-D", "--debug", "--DEBUG" };
    for (test_cases) |test_arg| {
        var test_args = try toArgList(&[_]String{test_arg});
        defer test_args.clearAndFree();

        var args = try parseArgs(test_args, test_alloc);
        defer args.run_type.deinit();
        try expect(args.debug_mode);
    }

    const negatives = &[_]String{ "-v", "-F", "--fersion", "" };
    for (negatives) |test_arg| {
        var test_args = try toArgList(&[_]String{test_arg});
        defer test_args.clearAndFree();

        var args = try parseArgs(test_args, test_alloc);
        defer args.run_type.deinit();
        try expect(!args.debug_mode);
    }
}

test "parseArgs parses file name" {
    const test_cases = &[_]String{ "file", "insert/file/here" };
    for (test_cases) |test_arg| {
        var test_args = try toArgList(&[_]String{test_arg});
        defer test_args.clearAndFree();

        var args = try parseArgs(test_args, test_alloc);
        defer args.run_type.deinit();
        try expectEqualStrings(test_arg, args.run_type.file.value);
    }

    const negatives = &[_]String{ "-v", "-F", "--fersion", "" };
    for (negatives) |test_arg| {
        var test_args = try toArgList(&[_]String{test_arg});
        defer test_args.clearAndFree();

        var args = try parseArgs(test_args, test_alloc);
        defer args.run_type.deinit();
        try expect(args.run_type != RunType.file);
    }
}
