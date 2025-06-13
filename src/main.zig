const std = @import("std");

const runner = @import("runner.zig");
const repl = @import("repl.zig");
const file = @import("file.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var args = try std.process.ArgIterator.initWithAllocator(gpa.allocator());
    defer args.deinit();

    var file_name: []const u8 = "";

    _ = args.next(); // Discard program name
    if (args.next()) |arg| {
        file_name = arg;
    }

    var ui = if (file_name.len > 0)
        runner.UserInterface{ .file = file.InitStdFile(
            runner.line_size,
            file_name,
            gpa.allocator(),
        ) }
    else
        runner.UserInterface{ .repl = try repl.InitStdRepl() };

    try runner.run(&ui, gpa.allocator());
}

const expect = std.testing.expect;

test {
    std.testing.refAllDecls(@This());
}
