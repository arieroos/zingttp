const std = @import("std");

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

    fn resolveVariable(self: *Context, key: String) !?Variable {
        var spliterator = std.mem.splitScalar(u8, key, '.');

        while (spliterator.next()) |part| {
            if (part.len == 0) {
                continue;
            }
            return if (strings.eql(part, "last_request"))
                try self.resolveReqVariable(spliterator.rest())
            else
                null;
        }

        return null;
    }

    fn resolveReqVariable(self: *Context, key: String) !?Variable {
        if (self.last_req == null) {
            return null;
        }
        const lr = self.last_req.?;

        var spliterator = std.mem.splitScalar(u8, key, '.');

        while (spliterator.next()) |part| {
            if (part.len == 0) {
                continue;
            }

            while (spliterator.peek()) |p| {
                if (p.len > 0) {
                    break;
                }
                _ = spliterator.next();
            }

            if (strings.eql(part, "method") and spliterator.peek() == null)
                return try Variable.fromStr(lr.method.value, self.allocator);
            if (strings.eql(part, "url") and spliterator.peek() == null)
                return try Variable.fromStr(lr.url.value, self.allocator);
            if (strings.eql(part, "time_spent") and spliterator.peek() == null)
                return Variable.fromInt(u64, lr.time_spent / std.time.ns_per_ms);
            if (strings.eql(part, "success") and spliterator.peek() == null)
                return Variable.fromBool(switch (lr.response) {
                    .failure => false,
                    .success => true,
                });

            if (strings.eql(part, "headers"))
                return resolveHeaderVariable(self.last_req.?.headers, spliterator.rest(), self.allocator);
        }

        var buf: [1024]u8 = undefined;
        const msg = try switch (lr.response) {
            .failure => std.fmt.bufPrint(&buf, "{s} request to {s} failed: {s}: {s}", .{
                lr.method.value,
                lr.url.value,
                lr.response.failure.reason,
                @errorName(lr.response.failure.base_err),
            }),
            .success => std.fmt.bufPrint(&buf, "{s} request to {s} succeeded: {} - {s}", .{
                lr.method.value,
                lr.url.value,
                lr.response.success.code,
                std.http.Status.phrase(lr.response.success.code) orelse "Unknown",
            }),
        };
        return try Variable.fromStr(msg, self.allocator);
    }
};

fn resolveHeaderVariable(
    headers: http.HeaderMap,
    key: String,
    allocator: std.mem.Allocator,
) !?Variable {
    var spliterator = std.mem.splitScalar(u8, key, '.');

    while (spliterator.next()) |part| {
        if (part.len == 0) {
            continue;
        }
        advanceSpliterator(&spliterator);

        const lower_part = try std.ascii.allocLowerString(allocator, part);
        defer allocator.free(lower_part);

        if (headers.map.get(lower_part)) |header| {
            var header_list = try Variable.fromArrayList(String, header.*, allocator);
            defer header_list.deinit();

            const found = variable.resolveVariableFromPath(header_list, spliterator.rest());
            return if (found) |f| try f.copy(allocator) else null;
        } else return null;
    }
    // TODO: find a way to represent all the headers and their values
    return try Variable.fromStr("TODO req headers full", allocator);
}

fn advanceSpliterator(s: *std.mem.SplitIterator(u8, std.mem.DelimiterType.scalar)) void {
    while (s.peek()) |p| {
        if (p.len > 0) {
            break;
        }
        _ = s.next();
    }
}

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

    var result = try http.Request.init(req.method, url, ctx.allocator);
    errdefer result.deinit();

    _ = ctx.client.do(&result, ctx.options);
    switch (result.response) {
        .failure => |err| {
            try ctx.ui.print(
                "Error while executing {s} command: {s}: {s}\n",
                .{ result.method.value, err.reason, @errorName(err.base_err) },
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
    ctx.last_req = result;
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
            .variable => |v| {
                var val = try ctx.resolveVariable(v);
                if (val == null) {
                    debug.println("{s} has null value", .{v});
                } else {
                    defer val.?.deinit();

                    const str_val = try val.?.toStrAlloc(ctx.allocator);
                    defer ctx.allocator.free(str_val);

                    try str_builder.appendSlice(str_val);
                }
            },
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

    ctx.last_req = try makeTestResponse("Something nice and long, we want to to check for memory leaks.");
    ctx.updateLastResponse(try makeTestResponse("Hi there!"));

    ctx.deinit();
    try expect(!std.testing.allocator_instance.detectLeaks());
}

test "Context.resolveReqVariable resolves request variables" {
    var ctx = makeTestCtx();
    defer ctx.deinit();

    ctx.last_req = try makeTestResponse("Some data in the reply");

    const cases = [_]struct { key: String, expected: String }{
        .{ .key = "method", .expected = "GET" },
        .{ .key = "url", .expected = "http://some_site.com" },
        .{ .key = "time_spent", .expected = "0" },
        .{ .key = "success", .expected = "true" },

        .{ .key = "headers.Content-Type", .expected = "[\n\tapplication/json\n]" },
        .{ .key = "headers.Content-Type.0", .expected = "application/json" },

        .{ .key = "", .expected = "GET request to http://some_site.com succeeded: http.Status.ok - OK" },
    };

    inline for (&cases) |case| {
        var var_val = try ctx.resolveReqVariable(case.key);
        if (var_val == null) {
            std.log.err("Unexpected null value for key {s}", .{case.key});
            try expect(false);
        }
        defer var_val.?.deinit();

        const str = try var_val.?.toStrAlloc(test_alloc);
        defer test_alloc.free(str);

        try expectEqualStrings(case.expected, str);
    }
}

test "resolveArguments resolves arguments" {
    var ctx = makeTestCtx();
    defer ctx.deinit();

    ctx.updateLastResponse(try makeTestResponse(""));

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
        "Error: Expected value or variable but found whitespace at 9: ",
        "GET https://jsonplaceholder.typicode.com/posts/1",
    };
    try runFileTest("tests/invalid.http", expecteds);
}

test "Run print file" {
    const expecteds = &[_]String{
        "argument",
        "literal argument",
        "",
        "",
        "Received response 200 (OK):",
        "GET request to https://jsonplaceholder.typicode.com/posts/1 succeeded: http.Status.ok - OK",
        "GET",
        "GET",
        "GET",
        "Hi mom! I made a \"GET\" request to https://jsonplaceholder.typicode.com/posts/1!",
    };
    try runFileTest("tests/print.http", expecteds);
}
