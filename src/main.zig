const std = @import("std");
const build = @import("build");

const strings = @import("strings.zig");
const String = strings.String;

const runner = @import("runner.zig");
const repl = @import("repl.zig");
const file = @import("file.zig");

const RunType = union(enum) {
    repl: void,
    file: String,
    version: void,
};

const Args = struct {
    run_type: RunType,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var argArena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer argArena.deinit();
    const args = try readAndParseArgs(argArena.allocator());

    var ui: ?runner.UserInterface = null;
    switch (args.run_type) {
        .version => {
            try std.io.getStdOut().writer().print("ZingTTP {s}\n", .{build.manifest.version});
            return;
        },
        .file => |f| ui =
            runner.UserInterface{ .file = file.InitStdFile(runner.line_size, f, gpa.allocator()) },
        .repl => ui =
            runner.UserInterface{ .repl = try repl.InitStdRepl() },
    }

    try runner.run(&ui.?, gpa.allocator());
}

fn readAndParseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    var argList = std.ArrayList(String).init(allocator);

    _ = args.skip(); // Discard program name
    if (args.next()) |arg| {
        // for now we are just interested in the first arg, if there is one.
        // in the future this "if" might become a "while"
        try argList.append(arg);
    }

    return parseArgs(argList);
}

fn parseArgs(argList: std.ArrayList(String)) Args {
    const args = argList.items;
    if (args.len == 0) {
        return Args{ .run_type = RunType.repl };
    }

    const versionArgs = &[_]String{ "-v", "--version" };

    if (strings.iLstHas(versionArgs, args[0])) {
        return Args{ .run_type = RunType.version };
    }
    return Args{ .run_type = .{ .file = args[0] } };
}

const expect = std.testing.expect;
const test_alloc = std.testing.allocator;

test {
    std.testing.refAllDecls(@This());
}

fn toArgList(a: []const String) !std.ArrayList(String) {
    var l = try std.ArrayList(String).initCapacity(test_alloc, a.len);
    l.appendSliceAssumeCapacity(a);
    return l;
}

test "parseArgs parses version arg" {
    var testArgList = try toArgList(&[_]String{"-v"});
    defer testArgList.clearAndFree();

    try expect(parseArgs(testArgList).run_type == RunType.version);
}
