const std = @import("std");

const scanner = @import("scanner.zig");
const parser = @import("parser.zig");
const repl = @import("repl.zig");
const http = @import("http.zig");
const file = @import("file.zig");

pub const line_size = 1024;

const TestUi = struct {
    nextLine: []const u8 = "",
    printBuf: [line_size]u8 = undefined,
    lastResponse: []u8 = &.{},

    fn getNextLine(self: *TestUi, buffer: []u8) ![]u8 {
        if (self.nextLine.len == 0) {
            self.nextLine = "EXIT";
        }
        std.mem.copyForwards(u8, buffer, self.nextLine);
        const len = @min(buffer.len, self.nextLine.len);
        self.nextLine = "";
        return buffer[0..len];
    }

    fn print(self: *TestUi, comptime fmt: []const u8, args: anytype) !void {
        self.lastResponse = std.fmt.bufPrint(&self.printBuf, fmt, args) catch &self.printBuf;
    }

    fn exit(self: *TestUi) void {
        _ = self;
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

    var lineBuffer: [1024]u8 = undefined;
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
    const result = ctx.client.do(cmd.command, cmd.argument);

    ctx.last_response = result;
    if (result.fetch_error) |err| {
        try ctx.ui.print("Error while executing command: {s}", .{@errorName(err)});
    } else if (result.response_code) |rc| {
        const phrase = rc.phrase() orelse "Unknown";
        try ctx.ui.print("Received response: {} - {s} ({} bytes)\n", .{ @intFromEnum(rc), phrase, result.body.items.len });
    }
}

const test_alloc = std.testing.allocator;
const expect = std.testing.expect;

fn makeTestCtx() Context {
    var test_ui = UserInterface{ .testing = TestUi{} };
    return Context{
        .client = http.client(test_alloc),
        .ui = &test_ui,
    };
}

test run {
    var testUi = UserInterface{ .testing = TestUi{} };
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
