// This is just a simple webserver to echo responses for testing

const std = @import("std");
const http = std.http;

const stdout = std.io.getStdOut().writer();

const strings = @import("../strings.zig");

const Options = struct {
    port: u16,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const options = try parseArgs(allocator);

    const address = try std.net.Address.parseIp4("127.0.0.1", options.port);
    var server = address.listen(.{}) catch |err| switch (err) {
        error.AddressInUse => {
            stdout.print("Address at 127.0.0.1:{} already in use\n", .{options.port}) catch unreachable;
            std.process.exit(1);
        },
        else => return err,
    };
    defer server.deinit();

    const request_buffer = try allocator.alloc(u8, 1024 * 32);
    defer allocator.free(request_buffer);

    try stdout.print("Listening on {}\n", .{options.port});
    while (true) {
        var conn = try server.accept();
        defer conn.stream.close();

        const now = @mod(std.time.timestamp(), std.time.s_per_day);
        const now_hour = @divFloor(now, std.time.s_per_hour);
        const now_minute = @divFloor(@mod(now, std.time.s_per_hour), std.time.s_per_min);
        const now_second = @mod(now, std.time.s_per_min);

        try stdout.print("-" ** 64 ++ "\n", .{});
        try stdout.print("New request Received\n", .{});
        try stdout.print("Time: {}:{}:{}\n", .{ now_hour, now_minute, now_second });
        try stdout.print("-" ** 64 ++ "\n", .{});

        var http_server = http.Server.init(conn, request_buffer);
        var req = try http_server.receiveHead();
        errdefer req.respond("", .{ .status = http.Status.internal_server_error }) catch |err| {
            stdout.print("Could not send error 500: {s}", .{@errorName(err)}) catch unreachable;
        };

        try stdout.print("{s}\n", .{req.head.target});

        var header_it = req.iterateHeaders();
        while (header_it.next()) |h| {
            try stdout.print("{s}: {s}\n", .{ h.name, h.value });
        }

        handleRoute(req.head.target);

        try req.respond("Hi daar slaaiblaar!", .{});
        try stdout.print("\n", .{});
    }
}

fn handleRoute(route: []const u8) void {
    if (std.mem.containsAtLeast(u8, route, 1, "wait")) {
        std.time.sleep(std.time.ns_per_s);
    }
}

fn parseArgs(allocator: std.mem.Allocator) !Options {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var args = try std.process.ArgIterator.initWithAllocator(arena.allocator());
    _ = args.skip();

    var options = Options{ .port = 9009 };

    var port_next = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p")) {
            port_next = true;
            continue;
        }
        if (port_next) {
            options.port = try std.fmt.parseInt(u16, arg, 10);
            port_next = false;
        }
    }

    return options;
}
