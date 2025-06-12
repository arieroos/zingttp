const std = @import("std");

const stdin = std.io.getStdIn().reader();
const stdout = std.io.getStdOut().writer();

pub const StdRepl = Repl(@TypeOf(stdin), @TypeOf(stdout));

pub fn InitStdRepl() !StdRepl {
    return StdRepl.init(stdin, stdout);
}

pub fn Repl(comptime Reader: type, comptime Writer: type) type {
    return struct {
        const Self = @This();

        stdin: Reader,
        stdout: Writer,

        pub fn init(in: Reader, out: Writer) !Self {
            try out.print("ZingTTP: A Language for Testing HTTP Services\n", .{});

            return Self{ .stdin = in, .stdout = out };
        }

        pub fn getNextLine(self: *Self, buffer: []u8) ![]u8 {
            try self.stdout.print("> ", .{});
            return stdin.readUntilDelimiterOrEof(buffer, '\n');
        }

        pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            try self.stdout.print(fmt, args);

            if (!std.mem.endsWith(u8, fmt, "\n")) {
                try self.stdout.print("\n", .{});
            }
        }
    };
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const testAlloc = std.testing.allocator;

test Repl {
    var buffer: [1024]u8 = undefined;
    var testStream = std.io.fixedBufferStream(&buffer);
    const writer = testStream.writer();
    const reader = testStream.reader();

    var repl = try Repl(@TypeOf(reader), @TypeOf(writer)).init(reader, writer);
    try expectEqualStrings("ZingTTP:", buffer[0..8]);

    testStream.reset();
    try repl.print("hello {s}", .{"there"});
    try expectEqualStrings("hello there\n", buffer[0..12]);

    try testStream.seekTo(2);
    _ = try testStream.write("Some line here\n");
    testStream.reset();
    const line = try repl.getNextLine(testAlloc);
    if (line) |l| {
        defer l.deinit();
        try expectEqualStrings("Some line here", l.items[0..14]);
    } else {
        try expect(false);
    }
}
