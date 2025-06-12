const std = @import("std");

const runner = @import("runner.zig");
const repl = @import("repl.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var ui = runner.UserInterface{ .repl = try repl.InitStdRepl() };
    try runner.run(&ui, gpa.allocator());
}

const expect = std.testing.expect;

test {
    std.testing.refAllDecls(@This());
}
