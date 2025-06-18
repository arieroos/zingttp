const std = @import("std");

const debug = @import("debug.zig");

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
        debug.println0("Sending user feedback");
        switch (self.*) {
            inline else => |*impl| return impl.print(fmt, args),
        }
    }

    fn exit(self: *UserInterface) void {
        debug.println0("Exiting...");
        switch (self.*) {
            inline else => |*impl| return impl.exit(),
        }
    }
};

const Context = struct {
    client: http.Client,
    ui: *UserInterface,
    last_req: ?http.Request = null,
    options: http.Options = .{},
    // TODO: A way to specify options

    fn update_last_response(self: *Context, new: http.Request) void {
        var old = self.last_req;
        self.last_req = new;
        if (old) |*o|
            o.deinit();
    }

    fn deinit(self: *Context) void {
        if (self.last_req) |*r| r.deinit();
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
    const result = ctx.client.do(cmd.command, cmd.argument, ctx.options);

    ctx.last_req = result;
    switch (result.response) {
        .failure => |err| {
            try ctx.ui.print(
                "Error while executing {s} command: {s}: {s}\n",
                .{ result.method, err.reason, @errorName(err.base_err) },
            );
        },
        .success => |r| {
            const phrase = r.code.phrase() orelse "Unknown";
            const spent_ms = result.time_spent / std.time.ns_per_ms;
            try ctx.ui.print(
                "Received response {} ({s}): {} bytes in {} millisconds\n",
                .{ @intFromEnum(r.code), phrase, r.body.items.len, spent_ms },
            );
        },
    }
}

const test_alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectStringStartsWith = std.testing.expectStringStartsWith;

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

fn makeTestResponse(body: []const u8) !http.Request {
    var body_arr = std.ArrayList(u8).init(test_alloc);
    try body_arr.appendSlice(body);

    return http.Request{
        .headers = http.HeaderMap.init(test_alloc),
        .method = "",
        .url = "",
        .response = .{ .success = .{
            .body = body_arr,
            .headers = http.HeaderMap.init(test_alloc),
            .code = std.http.Status.ok,
        } },
    };
}

test "Context update response without leaking memory" {
    var ctx = makeTestCtx();
    errdefer ctx.deinit();

    ctx.last_req = try makeTestResponse("Something nice and long, we want to to check for memory leaks.");
    ctx.update_last_response(try makeTestResponse("Hi there!"));

    ctx.deinit();
    try expect(!std.testing.allocator_instance.detectLeaks());
}

fn makeTestUiFromFile(file_path: []const u8, allocator: std.mem.Allocator) !UserInterface {
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

    var testUi = try makeTestUiFromFile(file_name, arena.allocator());
    defer testUi.testing.deinit();

    try run(&testUi, test_alloc);

    const outputs = testUi.testing.getOutputMsgs();
    try expect(outputs.len == expected_lines.len);
    for (outputs, expected_lines) |output, expected| {
        try expectStringStartsWith(output, expected);
    }
}

test "Run basic file" {
    const expecteds = &[_][]const u8{
        "Received response 200 (OK): 292 bytes in",
    };
    try runFileTest("tests/basic.http", expecteds);
}

test "Run invalid file" {
    const expecteds = &[_][]const u8{
        "Error: Statement does not start with keyword\n",
        "Error: Unexpected token at 5: \"after\"\n",
        "Error: Unexpected token at 42: \"posts/1\"\n",
        "Error: Missing value at 5\n",
        "Error: Expected value but found keyword at 4: \"EXIT\"\n",
        "Received response 200 (OK): 292 bytes in",
    };
    try runFileTest("tests/invalid.http", expecteds);
}
