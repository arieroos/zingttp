const std = @import("std");

const strings = @import("strings.zig");
const String = strings.String;
const StringBuilder = strings.StringBuilder;

const debug = @import("debug.zig");

const scanner = @import("scanner.zig");
const parser = @import("parser.zig");
const repl = @import("repl.zig");
const http = @import("http.zig");
const file = @import("file.zig");

pub const line_size = 1024;

const TestUi = struct {
    inputs: []const String,
    outputs: std.ArrayList(String),
    allocator: std.mem.Allocator,

    input_idx: usize = 0,

    fn init(lines: []const String, allocator: std.mem.Allocator) TestUi {
        return TestUi{
            .inputs = lines,
            .outputs = std.ArrayList(String).init(allocator),
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

    fn print(self: *TestUi, comptime fmt: String, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.outputs.append(msg);
    }

    fn getOutputMsgs(self: *TestUi) []const String {
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

    fn print(self: *UserInterface, comptime fmt: String, args: anytype) !void {
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
    allocator: std.mem.Allocator,

    client: http.Client,
    ui: *UserInterface,

    last_req: ?http.Request = null,
    options: http.Options = .{},
    // TODO: A way to specify options

    fn updateLastResponse(self: *Context, new: http.Request) void {
        var old = self.last_req;
        self.last_req = new;
        if (old) |*o| o.deinit();
    }

    fn deinit(self: *Context) void {
        if (self.last_req) |*r| r.deinit();
        self.client.deinit();
    }
};

const RequestExpr = parser.Request;
const ArgList = parser.ArgList;

pub fn run(ui: *UserInterface, allocator: std.mem.Allocator) !void {
    var ctx = Context{ .allocator = allocator, .client = http.client(allocator), .ui = ui };
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

        var expression = try parser.parse(tokens, allocator);
        defer expression.deinit(allocator);

        switch (expression) {
            .nothing => continue,
            .exit => {
                ui.exit();
                break;
            },
            .invalid => |inv| try ui.print("Error: {s}\n", .{inv}),
            .request => |req| try doRequest(&ctx, req),
            .print => |p| try doPrint(&ctx, p),
        }
    }
}

fn doRequest(ctx: *Context, req: RequestExpr) !void {
    const url = try resolveArguments(ctx, req.arguments);
    defer ctx.allocator.free(url);

    const result = ctx.client.do(req.method, url, ctx.options);

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

fn doPrint(ctx: *Context, args: ArgList) !void {
    const to_print = try resolveArguments(ctx, args);
    defer ctx.allocator.free(to_print);

    try ctx.ui.print("{s}\n", .{to_print});
}

fn resolveArguments(ctx: *Context, args: ArgList) !String {
    if (args.items.len == 0) {
        return "";
    }

    var str_builder = StringBuilder.init(ctx.allocator);
    defer str_builder.clearAndFree();

    for (args.items) |arg| {
        switch (arg) {
            .value => |v| try str_builder.appendSlice(v),
            .variable => |v| try str_builder.appendSlice(v),
        }
    }

    return try str_builder.toOwnedSlice();
}

const test_alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectStringStartsWith = std.testing.expectStringStartsWith;

fn makeTestUi(inputs: []const String) UserInterface {
    return UserInterface{ .testing = TestUi.init(inputs, test_alloc) };
}

fn makeTestCtx() Context {
    var test_ui = makeTestUi(&[_]String{});
    return Context{
        .allocator = test_alloc,
        .client = http.client(test_alloc),
        .ui = &test_ui,
    };
}

test run {
    var test_ui = makeTestUi(&[_]String{});
    try run(&test_ui, test_alloc);
}

test "run can make a request and print the requested url" {
    const cmds = [_]String{
        "GET https://jsonplaceholder.typicode.com/posts/1",
        "PRINT Done",
        "PRINT Made' a '{{last_reg.method}}' request to '{{ last_req.url }}",
    };
    var test_ui = makeTestUi(&cmds);
    defer test_ui.testing.deinit();

    try run(&test_ui, test_alloc);

    const outputs = test_ui.testing.getOutputMsgs();
    try expect(outputs.len == 3);
    try expectStringStartsWith(outputs[1], "Done");
    try expectStringStartsWith(outputs[2], "Made a GET request to https://jsonplaceholder.typicode.com/posts/1");
}

fn makeTestResponse(body: String) !http.Request {
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

test "Context.updateLastResponse does not leak memory" {
    var ctx = makeTestCtx();
    errdefer ctx.deinit();

    ctx.last_req = try makeTestResponse("Something nice and long, we want to to check for memory leaks.");
    ctx.updateLastResponse(try makeTestResponse("Hi there!"));

    ctx.deinit();
    try expect(!std.testing.allocator_instance.detectLeaks());
}

test "resolveArguments resolves arguments" {
    var ctx = makeTestCtx();
    defer ctx.deinit();

    const args = [_]parser.Argument{
        .{ .value = "Made" },
        .{ .value = " a " },
        .{ .variable = "last_req.method" },
        .{ .value = " Request" },
    };
    var arg_list = try ArgList.initCapacity(test_alloc, args.len);
    defer arg_list.clearAndFree();
    arg_list.appendSliceAssumeCapacity(&args);

    const resolved = try resolveArguments(&ctx, arg_list);
    defer test_alloc.free(resolved);

    try expectEqualStrings("Made a GET Request", resolved);
}

fn makeTestUiFromFile(file_path: String, allocator: std.mem.Allocator) !UserInterface {
    var test_file = try std.fs.cwd().openFile(file_path, .{ .lock = .shared });
    defer test_file.close();
    const file_reader = test_file.reader();

    var lines = std.ArrayList(String).init(allocator);
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

fn runFileTest(file_name: String, expected_lines: []const String) !void {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    defer arena.deinit();

    var test_ui = try makeTestUiFromFile(file_name, arena.allocator());
    defer test_ui.testing.deinit();

    try run(&test_ui, test_alloc);

    const outputs = test_ui.testing.getOutputMsgs();
    try expect(outputs.len == expected_lines.len);
    for (outputs, expected_lines) |output, expected| {
        try expectStringStartsWith(output, expected);
    }
}

test "Run basic file" {
    const expecteds = &[_]String{
        "Received response 200 (OK): 292 bytes in",
    };
    try runFileTest("tests/basic.http", expecteds);
}

test "Run invalid file" {
    const expecteds = &[_]String{
        "Error: Statement does not start with keyword\n",
        "Error: Unexpected token at 4: \" \"\n",
        "Error: Expected value or variable but found whitespace at 41: \" \"\n",
        "Error: Missing value or variable at 4\n",
        "Error: Expected value or variable but found keyword at 4: \"EXIT\"\n",
        "Received response 200 (OK): 292 bytes in",
    };
    try runFileTest("tests/invalid.http", expecteds);
}
