const std = @import("std");

const stdin = std.io.getStdIn().reader();
const stdout = std.io.getStdOut().writer();

pub fn main() !void {
    try stdout.print("ZingHTL: Zing HTTP Testing Language\n", .{});

    var inputBuffer: [1024]u8 = undefined;
    while (true) {
        try stdout.print("> ", .{});

        const line = try stdin.readUntilDelimiter(&inputBuffer, '\n');
        if (std.mem.eql(u8, line, "EXIT")) {
            break;
        }

        try stdout.print("{s}\n", .{line});
    }
}
