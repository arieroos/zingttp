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

            var bufStream = std.io.fixedBufferStream(buffer);
            self.stdin.streamUntilDelimiter(bufStream.writer(), '\n', buffer.len) catch |err| switch (err) {
                error.EndOfStream => {},
                else => return err,
            };
            return bufStream.getWritten();
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
    var test_stream = std.io.fixedBufferStream(&buffer);
    const writer = test_stream.writer();
    const reader = test_stream.reader();

    var repl = try Repl(@TypeOf(reader), @TypeOf(writer)).init(reader, writer);
    try expectEqualStrings("ZingTTP:", buffer[0..8]);

    test_stream.reset();
    try repl.print("hello {s}", .{"there"});
    try expectEqualStrings("hello there\n", buffer[0..12]);

    try test_stream.seekTo(2);
    _ = try test_stream.write("Some line here\n");
    test_stream.reset();

    var line_buf: [1024]u8 = undefined;
    const line = try repl.getNextLine(&line_buf);
    try expectEqualStrings("Some line here", line);
}
