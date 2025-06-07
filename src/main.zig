const std = @import("std");

const stdin = std.io.getStdIn().reader();
const stdout = std.io.getStdOut().writer();

pub const scanner = @import("scanner.zig");

pub fn getError(err: anyerror) ![]const u8 {
    return switch (err) {
        scanner.ScannerError.LineDoesNotStartWithKeyword => "Every line should start with a keyword!",
        else => err,
    };
}

pub fn main() !void {
    try stdout.print("ZingHTL: Zing HTTP Testing Language\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var inputBuffer: [1024]u8 = undefined;
    while (true) {
        try stdout.print("> ", .{});

        const line = try stdin.readUntilDelimiter(&inputBuffer, '\n');

        var tokenList = scanner.scan(line, gpa.allocator()) catch |err| blk: {
            _ = try std.io.getStdErr().writer().print("{s}\n", .{try getError(err)});
            break :blk std.ArrayList(scanner.Token).init(gpa.allocator());
        };
        defer tokenList.deinit();

        const tokens = tokenList.items;
        if (tokens.len == 0) {
            continue;
        }

        if (tokens[0].type.isKeyword(scanner.Keyword.EXIT)) {
            break;
        }

        for (tokens) |token| {
            var toStrBuffer: [32]u8 = undefined;
            const typeStr = token.type.toString(&toStrBuffer);
            try stdout.print("--- {s} for {s} at {}\n", .{ typeStr, token.lexeme, token.pos });
        }
    }
}

const expect = std.testing.expect;

test "testing works" {
    std.testing.refAllDecls(@This());
    try expect(true);
}
