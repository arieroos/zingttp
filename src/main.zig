const std = @import("std");

const stdin = std.io.getStdIn().reader();
const stdout = std.io.getStdOut().writer();

pub const scanner = @import("scanner.zig");
pub const parser = @import("parser.zig");

pub fn main() !void {
    try stdout.print("ZingTTP: A Language for Testing HTTP Services \n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var inputBuffer: [1024]u8 = undefined;
    while (true) {
        try stdout.print("> ", .{});

        const line = try stdin.readUntilDelimiter(&inputBuffer, '\n');

        var tokens = try scanner.scan(line, gpa.allocator());
        defer tokens.deinit();

        const expression = try parser.parse(tokens);
        switch (expression) {
            .nothing => continue,
            .exit => {
                try stdout.print("Bye!\n", .{});
                break;
            },
            .invalid => |msg| try stdout.print("Error: {s}\n", .{msg}),
            .command => |cmd| try stdout.print("{s} command for {s}\n", .{ cmd.command, cmd.argument }),
        }
    }
}

const expect = std.testing.expect;

test {
    std.testing.refAllDecls(@This());
}
