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

        var tokenList = try scanner.scan(line, gpa.allocator());
        defer tokenList.deinit();

        const tokens = tokenList.items;
        if (tokens.len == 0) {
            continue;
        }

        if (tokens[0].token.isKeyword(scanner.Keyword.EXIT)) {
            break;
        }

        for (tokens) |token| {
            var toStrBuffer: [32]u8 = undefined;
            const typeStr = token.token.toString(&toStrBuffer);
            try stdout.print("--- {s} for {s} at {}\n", .{ typeStr, token.lexeme, token.pos });
        }
    }
}

const expect = std.testing.expect;

test {
    std.testing.refAllDecls(@This());
}
