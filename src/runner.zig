const std = @import("std");

const scanner = @import("scanner.zig");
const parser = @import("parser.zig");
const repl = @import("repl.zig");
const http = @import("http.zig");
const file = @import("file.zig");

pub const line_size = 1024;

const TestUi = struct {
    inputs: []const []const u8,
    outputs: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    input_idx: usize = 0,

    fn init(lines: []const []const u8, allocator: std.mem.Allocator) TestUi {
        return TestUi{
            .inputs = lines,
            .outputs = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    fn getNextLine(self: *TestUi, buffer: []u8) ![]u8 {
        if (self.input_idx == self.inputs.len) {
            return error.EndOfFile;
        }

        const line = self.inputs[self.input_idx];
        self.input_idx += 1;

        std.mem.copyForwards(u8, buffer, line);
        const len = @min(buffer.len, line.len);
        return buffer[0..len];
    }

    fn print(self: *TestUi, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.outputs.append(msg);
    }

    fn getOutputMsgs(self: *TestUi) []const []const u8 {
        return self.outputs.items;
    }

    fn exit(self: *TestUi) void {
        _ = self;
    }

    fn deinit(self: *TestUi) void {
        for (self.outputs.items) |output| {
            self.allocator.free(output);
        }
        self.outputs.deinit();
    }
};

pub const UserInterface = union(enum) {
    repl: repl.StdRepl,
    file: file.StdFile(line_size),
    testing: TestUi,

    fn getNextLine(self: *UserInterface, buffer: []u8) ![]u8 {
        switch (self.*) {
            inline else => |*impl| return impl.getNextLine(buffer),
        }
    }

    fn print(self: *UserInterface, comptime fmt: []const u8, args: anytype) !void {
        switch (self.*) {
            inline else => |*impl| return impl.print(fmt, args),
        }
    }

    fn exit(self: *UserInterface) void {
        switch (self.*) {
            inline else => |*impl| return impl.exit(),
        }
    }
};

const Context = struct {
    client: http.Client,
    ui: *UserInterface,
    last_response: ?http.Response = null,

    fn update_last_response(self: *Context, new: http.Response) void {
        var old = self.last_response;
        self.last_response = new;
        if (old) |*o| {
            o.body.clearAndFree();
        }
    }

    fn deinit(self: *Context) void {
        if (self.last_response) |*r| r.body.clearAndFree();
        self.client.deinit();
    }
};

const Command = parser.Command;

pub fn run(ui: *UserInterface, allocator: std.mem.Allocator) !void {
    var ctx = Context{ .client = http.client(allocator), .ui = ui };
    defer ctx.deinit();

    var lineBuffer: [line_size]u8 = undefined;
    while (true) {
        const line = ui.getNextLine(&lineBuffer) catch |err| switch (err) {
            error.EndOfFile => {
                ui.exit();
                break;
            },
            else => return err,
        };
        var tokens = try scanner.scan(line, allocator);
        defer tokens.deinit();

        const expression = try parser.parse(tokens);
        switch (expression) {
            .nothing => continue,
            .exit => {
                ui.exit();
                break;
            },
            .invalid => |inv| try ui.print("Error: {s}\n", .{inv.message}),
            .command => |cmd| try run_command(&ctx, cmd),
        }
    }
}

fn run_command(ctx: *Context, cmd: Command) !void {
    var timer = try std.time.Timer.start();
    const result = ctx.client.do(cmd.command, cmd.argument);

    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    ctx.last_response = result;
    if (result.fetch_error) |err| {
        try ctx.ui.print("Error while executing command: {s}", .{@errorName(err)});
    } else if (result.response_code) |rc| {
        const phrase = rc.phrase() orelse "Unknown";
        try ctx.ui.print(
            "Received response {} ({s}): {} bytes in {} millisconds\n",
            .{ @intFromEnum(rc), phrase, result.body.items.len, elapsed_ms },
        );
    }
}

const test_alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

fn makeTestUi(inputs: []const []const u8) UserInterface {
    return UserInterface{ .testing = TestUi.init(inputs, test_alloc) };
}

fn makeTestCtx() Context {
    var test_ui = makeTestUi(&[_][]const u8{});
    return Context{
        .client = http.client(test_alloc),
        .ui = &test_ui,
    };
}

test run {
    var testUi = makeTestUi(&[_][]const u8{});
    try run(&testUi, test_alloc);
}

test "Context update response without leaking memory" {
    var response1 = std.ArrayList(u8).init(test_alloc);
    try response1.appendSlice("Something nice and long, we want to to check for memory leaks.");
    var response2 = std.ArrayList(u8).init(test_alloc);
    try response2.appendSlice("Hi there!");

    var ctx = makeTestCtx();
    defer ctx.deinit();

    ctx.last_response = .{ .body = response1 };
    ctx.update_last_response(.{ .body = response2 });
}

fn makeTestuiFromFile(file_path: []const u8, allocator: std.mem.Allocator) !UserInterface {
    var test_file = try std.fs.cwd().openFile(file_path, .{ .lock = .shared });
    defer test_file.close();
    const file_reader = test_file.reader();

    var lines = std.ArrayList([]const u8).init(allocator);
    var eof = false;
    while (!eof) {
        var array_list = std.ArrayList(u8).init(allocator);

        file_reader.streamUntilDelimiter(array_list.writer(), '\n', line_size) catch |err| switch (err) {
            error.EndOfStream => eof = true,
            else => return err,
        };

        try lines.append(array_list.items);
    }

    return makeTestUi(lines.items);
}

fn runFileTest(file_name: []const u8, expected_lines: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    defer arena.deinit();

    var testUi = try makeTestuiFromFile(file_name, arena.allocator());
    defer testUi.testing.deinit();

    try run(&testUi, test_alloc);

    const outputs = testUi.testing.getOutputMsgs();
    try expect(outputs.len == expected_lines.len);
    for (outputs, expected_lines) |output, expected| {
        try expectEqualStrings(expected, output);
    }
}

test "Run basic file" {
    const expecteds = &[_][]const u8{
        "Received response: 200 - OK (292 bytes)\n",
    };
    try runFileTest("tests/basic.htl", expecteds);
}

test "Run invalid file" {
    const expecteds = &[_][]const u8{
        "Error: Statement does not start with keyword\n",
        "Error: Unexpected token at 5: \"after\"\n",
        "Error: Unexpected token at 42: \"posts/1\"\n",
        "Error: Missing value at 5\n",
        "Error: Expected value but found keyword at 4: \"EXIT\"\n",
        "Received response: 200 - OK (292 bytes)\n",
    };
    try runFileTest("tests/invalid.htl", expecteds);
}
