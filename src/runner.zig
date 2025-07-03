const std = @import("std");
const Allocator = std.mem.Allocator;

const strings = @import("strings.zig");
const String = strings.String;
const StringBuilder = strings.StringBuilder;

const debug = @import("debug.zig");

const scanner = @import("scanner.zig");
const parser = @import("parser.zig");
const RequestExpr = parser.Request;
const ArgList = parser.ArgList;

const variable = @import("variable.zig");
const Variable = variable.Variable;

const repl = @import("repl.zig");
const http = @import("http.zig");
const file = @import("file.zig");

pub const line_size = 1024;

const TestUi = struct {
    inputs: []const String,
    outputs: std.ArrayList(String),
    allocator: Allocator,

    input_idx: usize = 0,

    fn init(lines: []const String, allocator: Allocator) TestUi {
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
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,

    client: http.Client,
    ui: *UserInterface,

    variables: Variable,

    options: http.Options = .{},
    // TODO: A way to specify options

    fn init(ui: *UserInterface, allocator: Allocator) Context {
        return Context{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .client = http.client(allocator),
            .ui = ui,
            .variables = Variable.initMap(allocator),
        };
    }

    fn updateLastResponse(self: *Context, new: http.Request) !void {
        debug.println0("Updating last request variable");

        const req_var = try requestToVar(new, self.allocator);
        try self.variables.mapPut("last_request", req_var, self.allocator);
    }

    fn deinit(self: *Context) void {
        self.arena.deinit();
        self.variables.deinit();
        self.client.deinit();
    }

    fn resolveVariable(self: *Context, key: String) ?Variable {
        return variable.resolveVariableFromPath(self.variables, key);
    }
};

fn requestToVar(req: http.Request, allocator: Allocator) !Variable {
    var map = Variable.initMap(allocator);
    errdefer map.deinit();

    try map.mapPutAny(String, "method", req.method, allocator);
    try map.mapPutAny(String, "url", req.url, allocator);
    try map.mapPutAny(u64, "time_spent", req.time_spent, allocator);
    try map.mapPutAny(bool, "success", req.isSuccess(), allocator);

    try map.mapPut("headers", try headerMapToVar(req.headers, allocator), allocator);

    const resp = try responseToVar(req.response, allocator);
    try map.mapPut("response", resp, allocator);

    return map;
}

fn responseToVar(resp: http.Response, allocator: Allocator) !Variable {
    var map = Variable.initMap(allocator);
    errdefer map.deinit();

    var buf: [256]u8 = undefined;
    try map.mapPutAny(String, "reason", try resp.reason(&buf), allocator);
    try map.mapPutAny(bool, "success", resp.isSuccess(), allocator);

    switch (resp) {
        .failure => {},
        .success => |s| {
            try map.mapPutAny(std.http.Status, "code", s.code, allocator);
            try map.mapPutAny(String, "body", s.body.items, allocator);

            try map.mapPut("headers", try headerMapToVar(s.headers, allocator), allocator);
        },
    }

    return map;
}

fn headerMapToVar(header_map: http.HeaderMap, allocator: Allocator) !Variable {
    var map = Variable.initMap(allocator);
    errdefer map.deinit();

    for (header_map.map.keys()) |key| {
        const list = try Variable.fromArrayList(String, header_map.map.get(key).?.*, allocator);
        try map.mapPut(key, list, allocator);
    }
    return map;
}

pub fn run(ui: *UserInterface, allocator: Allocator) !void {
    var ctx = Context.init(ui, allocator);
    defer ctx.deinit();

    const arena_alloc = ctx.arena.allocator();
    var lineBuffer: [line_size]u8 = undefined;
    while (true) {
        _ = ctx.arena.reset(.retain_capacity);

        const line = ui.getNextLine(&lineBuffer) catch |err| switch (err) {
            error.EndOfFile => {
                ui.exit();
                break;
            },
            else => return err,
        };
        debug.println("Processing line: {s}", .{line});

        const tokens = try scanner.scan(line, arena_alloc);
        const expression = try parser.parse(tokens, arena_alloc);

        switch (expression) {
            .nothing => continue,
            .exit => {
                ui.exit();
                break;
            },
            .invalid => |inv| try ui.print("Error: {s}\n", .{inv}),
            .request => |req| try doRequest(&ctx, req),
            .print => |p| try doPrint(&ctx, p),
            .set => |s| try ui.print(
                "set {s} to \"{s}\"\n",
                .{
                    try resolveArguments(&ctx, s.variable),
                    try resolveArguments(&ctx, s.value),
                },
            ),
        }
    }
}

fn doRequest(ctx: *Context, req: RequestExpr) !void {
    const url = try resolveArguments(ctx, req.arguments);

    var result = try http.Request.init(req.method, url, ctx.arena.allocator());
    defer result.deinit();

    ctx.client.do(&result, ctx.options);
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
    try ctx.updateLastResponse(result);
}

fn doPrint(ctx: *Context, args: ArgList) !void {
    const to_print = try resolveArguments(ctx, args);
    try ctx.ui.print("{s}\n", .{to_print});
}

fn resolveArguments(ctx: *Context, args: ArgList) !String {
    if (args.items.len == 0) {
        return "";
    }
    const allocator = ctx.arena.allocator();

    var str_builder = StringBuilder.init(allocator);
    for (args.items) |arg| {
        switch (arg) {
            .value => |v| try str_builder.appendSlice(v),
            .variable => |v| {
                var val = ctx.resolveVariable(v);
                if (val == null) {
                    debug.println("{s} has null value", .{v});
                } else {
                    const str_val = try val.?.toStrAlloc(allocator);
                    try str_builder.appendSlice(str_val);
                }
            },
        }
    }

    return str_builder.items;
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
    return Context.init(&test_ui, test_alloc);
}

test run {
    var test_ui = makeTestUi(&[_]String{});
    try run(&test_ui, test_alloc);
}

test "run can make a request and print the requested url" {
    const cmds = [_]String{
        "GET https://jsonplaceholder.typicode.com/posts/1",
        "PRINT Done",
        "PRINT Made' a '{{last_request.method}}' request to '{{ last_request.url }}",
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

    var req = try http.Request.init("GET", "http://some_site.com", test_alloc);
    try req.headers.putSingle("Content-Type", "application/json");
    req.response = .{ .success = .{
        .body = body_arr,
        .headers = http.HeaderMap.init(test_alloc),
        .code = std.http.Status.ok,
    } };
    return req;
}

test "Context.updateLastResponse does not leak memory" {
    var ctx = makeTestCtx();
    errdefer ctx.deinit();

    var resp1 = try makeTestResponse("Something nice and long, we want to to check for memory leaks.");
    try ctx.updateLastResponse(resp1);

    var resp2 = try makeTestResponse("Hi there!");
    try ctx.updateLastResponse(resp2);

    resp1.deinit();
    resp2.deinit();
    ctx.deinit();
    try expect(!std.testing.allocator_instance.detectLeaks());
}

test "Context.resolveVariable resolves request variables" {
    var ctx = makeTestCtx();
    defer ctx.deinit();

    var resp = try makeTestResponse("Some data in the reply");
    defer resp.deinit();
    try ctx.updateLastResponse(resp);

    const cases = [_]struct { key: String, expected: String }{
        .{
            .key = "",
            .expected = "{\n\turl: http://some_site.com,\n\tsuccess: true,\n\tmethod: GET,\n\ttime_spent: 0,\n\theaders: {\n\t\tcontent-type: [\n\t\t\tapplication/json\n\t\t]\n\t},\n\tresponse: {\n\t\tsuccess: true,\n\t\treason: 200 (OK),\n\t\tbody: Some data in the reply,\n\t\theaders: {},\n\t\tcode: 200\n\t}\n}",
        },

        .{ .key = "method", .expected = "GET" },
        .{ .key = "url", .expected = "http://some_site.com" },
        .{ .key = "time_spent", .expected = "0" },
        .{ .key = "success", .expected = "true" },
        .{ .key = "headers", .expected = "{\n\tcontent-type: [\n\t\tapplication/json\n\t]\n}" },

        .{ .key = "headers.content-type", .expected = "[\n\tapplication/json\n]" },
        .{ .key = "headers.content-type.0", .expected = "application/json" },
    };

    inline for (&cases) |case| {
        var var_val = ctx.resolveVariable("last_request." ++ case.key);
        if (var_val == null) {
            std.log.err("Unexpected null value for key {s}", .{case.key});
            try expect(false);
        }

        const str = try var_val.?.toStrAlloc(test_alloc);
        defer test_alloc.free(str);

        try expectEqualStrings(case.expected, str);
    }
}

test "resolveArguments resolves arguments" {
    var ctx = makeTestCtx();
    defer ctx.deinit();

    var resp = try makeTestResponse("");
    defer resp.deinit();

    try ctx.updateLastResponse(resp);

    const args = [_]parser.Argument{
        .{ .value = "Made" },
        .{ .value = " a " },
        .{ .variable = "last_request.method" },
        .{ .value = " Request" },
        .{ .variable = "method" },
    };
    var arg_list = try ArgList.initCapacity(test_alloc, args.len);
    defer arg_list.clearAndFree();
    arg_list.appendSliceAssumeCapacity(&args);

    const resolved = try resolveArguments(&ctx, arg_list);

    try expectEqualStrings("Made a GET Request", resolved);
}

fn makeTestUiFromFile(file_path: String, allocator: Allocator) !UserInterface {
    var test_file = try std.fs.cwd().openFile(file_path, .{ .lock = .shared });
    defer test_file.close();
    const file_reader = test_file.reader();

    var lines = std.ArrayList(String).init(allocator);
    var eof = false;
    while (!eof) {
        var array_list = std.ArrayList(u8).init(allocator);

        file_reader.streamUntilDelimiter(
            array_list.writer(),
            '\n',
            line_size,
        ) catch |err| switch (err) {
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

    const min = @min(outputs.len, expected_lines.len);

    for (outputs[0..min], expected_lines[0..min]) |output, expected| {
        try expectStringStartsWith(output, expected);
    }

    if (expected_lines.len > min) {
        for (expected_lines[min..]) |l| {
            std.log.err("Missing line from output: {s}", .{l});
        }
        try expect(false);
    }

    if (outputs.len > min) {
        for (outputs[min..]) |l| {
            std.log.err("Unexpected line in ouput: {s}", .{l});
        }
        try expect(false);
    }
}

test "Run basic file" {
    const expecteds = &[_]String{
        "Received response 200 (OK): 292 bytes in",
        "GET sent to https://jsonplaceholder.typicode.com/posts/1",
    };
    try runFileTest("tests/basic.zttp", expecteds);
}

test "Run invalid file" {
    const expecteds = &[_]String{
        "Error: Statement does not start with keyword\n",
        "Error: Unexpected token at 4: \" \"\n",
        "Error: Expected value or variable but found whitespace at 41: \" \"\n",
        "Error: Missing value or variable at 4\n",
        "Error: Expected value or variable but found keyword at 4: \"EXIT\"\n",
        "Received response 200 (OK): 292 bytes in",
        "Error: Expected value or variable but found whitespace at 9: ",
        "GET https://jsonplaceholder.typicode.com/posts/1",
    };
    try runFileTest("tests/invalid.zttp", expecteds);
}

test "Run print file" {
    const expecteds = &[_]String{
        "argument",
        "literal argument",
        "",
        "",
        "Received response 200 (OK):",
        "{\n\turl: https://jsonplaceholder.typicode.com/posts/1,\n",
        "GET",
        "GET",
        "GET",
        "Hi mom! I made a \"GET\" request to https://jsonplaceholder.typicode.com/posts/1!",
    };
    try runFileTest("tests/print.zttp", expecteds);
}
