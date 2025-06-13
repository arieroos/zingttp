const std = @import("std");
const fs = std.fs;

fn ChunkLine(comptime line_size: usize) type {
    return struct {
        line_buffer: [line_size]u8,
        pos: usize,
    };
}

pub fn File(comptime Out: type, comptime line_size: usize) type {
    return struct {
        const Self = @This();

        out: Out,
        file_path: []const u8,
        allocator: std.mem.Allocator,
        chunk: std.ArrayList(ChunkLine(line_size)),

        line_idx: usize = 0,
        max_chunk_size: usize = 32,
        chunk_size: usize = 0,

        pub fn init(out: Out, file_path: []const u8, allocator: std.mem.Allocator) Self {
            return Self{
                .out = out,
                .file_path = file_path,
                .allocator = allocator,
                .chunk = std.ArrayList(ChunkLine(line_size)).init(allocator),
            };
        }

        pub fn getNextLine(self: *Self, buffer: []u8) ![]u8 {
            var idx = self.chunkIdx();
            if (idx == 0) {
                try self.readNextChunk();
            }
            const lines = self.chunk.items;

            while (idx < self.chunk_size and lines[idx].pos == 0) {
                self.line_idx += 1;
                idx = self.chunkIdx();
            }

            if (idx >= lines.len) {
                return error.EndOfFile;
            }

            const cur_line = lines[idx];
            std.mem.copyForwards(u8, buffer, cur_line.line_buffer[0..cur_line.pos]);
            self.line_idx += 1;
            return buffer[0..cur_line.pos];
        }

        fn chunkIdx(self: *Self) usize {
            return @mod(self.line_idx, self.max_chunk_size);
        }

        fn readNextChunk(self: *Self) !void {
            var file = try fs.cwd().openFile(self.file_path, .{ .lock = .shared });
            defer file.close();
            const file_reader = file.reader();

            var lines_read: usize = 0;
            var eof = false;

            while (lines_read < self.max_chunk_size and !eof) : (lines_read += 1) {
                if (self.chunk.items.len < lines_read + 1) {
                    try self.chunk.append(.{ .line_buffer = undefined, .pos = 0 });
                }
                var chunk_line = &self.chunk.items[lines_read];

                var buffer = std.io.fixedBufferStream(&chunk_line.line_buffer);
                file_reader.streamUntilDelimiter(buffer.writer(), '\n', line_size) catch |err| switch (err) {
                    error.EndOfStream => eof = true,
                    else => return err,
                };
                chunk_line.pos = buffer.getWritten().len;
            }

            self.chunk_size = lines_read;
        }

        pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            try self.out.print("Line {}: " ++ fmt, .{self.line_idx} ++ args);
        }

        pub fn deinit(self: *Self) void {
            self.chunk.clearAndFree();
        }

        pub fn exit(self: *Self) void {
            self.deinit();
        }
    };
}

const stdout = std.io.getStdOut().writer();

pub fn StdFile(comptime line_size: usize) type {
    return File(@TypeOf(stdout), line_size);
}

pub fn InitStdFile(
    comptime line_size: usize,
    file_path: []const u8,
    allocator: std.mem.Allocator,
) StdFile(line_size) {
    return StdFile(line_size).init(stdout, file_path, allocator);
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const test_alloc = std.testing.allocator;

test File {
    var buffer: [1024]u8 = undefined;
    var test_stream = std.io.fixedBufferStream(&buffer);
    const writer = test_stream.writer();

    var test_file = File(@TypeOf(writer), 1024).init(writer, "tests/basic.htl", test_alloc);
    defer test_file.deinit();

    try test_file.print("hello {s}\n", .{"there"});
    try expectEqualStrings("Line 0: hello there\n", buffer[0..20]);

    var line_buf: [1024]u8 = undefined;
    const line = try test_file.getNextLine(&line_buf);
    try expectEqualStrings("# Just a basic test to see if we can script commands", line);

    test_stream.reset();
    try test_file.print("Should print for line 1", .{});
    try expectEqualStrings("Line 1: Should print for line 1", buffer[0..31]);
}
