const std = @import("std");
pub const Allocator = std.mem.Allocator;

pub const scanner = @import("scanner.zig");
pub const parser = @import("parser.zig");

pub const repl = @import("repl.zig");

const UserInterface = union(enum) {
    repl: repl.StdRepl,

    fn getNextLine(self: *UserInterface, alloc: Allocator) !?std.ArrayList(u8) {
        switch (self.*) {
            inline else => |*impl| return impl.getNextLine(alloc),
        }
    }

    fn print(self: *UserInterface, comptime fmt: []const u8, args: anytype) !void {
        switch (self.*) {
            inline else => |*impl| return impl.print(fmt, args),
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var ui = UserInterface{ .repl = try repl.InitStdRepl() };

    while (true) {
        var line = try ui.getNextLine(gpa.allocator()) orelse break;
        defer line.deinit();

        var tokens = try scanner.scan(line.items, gpa.allocator());
        defer tokens.deinit();

        const expression = try parser.parse(tokens);
        switch (expression) {
            .nothing => continue,
            .exit => {
                try ui.print("Bye!\n", .{});
                break;
            },
            .invalid => |inv| try ui.print("Error: {s}\n", .{inv.message}),
            .command => |cmd| try ui.print("{s} command for {s}\n", .{ cmd.command, cmd.argument }),
        }
    }
}

const expect = std.testing.expect;

test {
    std.testing.refAllDecls(@This());
}
