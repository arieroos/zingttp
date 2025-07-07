const std = @import("std");
const assert = std.debug.assert;

const http = std.http;
const StdClient = http.Client;

const build_info = @import("build");
const version = build_info.manifest.version;

const debug = @import("debug.zig");

const strings = @import("strings.zig");
const String = strings.String;
const StringBuilder = strings.StringBuilder;

pub fn client(allocator: std.mem.Allocator) Client {
    return Client{
        .client = StdClient{ .allocator = allocator },
        .allocator = allocator,
    };
}

pub const HeaderMap = struct {
    const MapType = std.StringArrayHashMap(*std.ArrayList(String));

    map: MapType,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HeaderMap {
        return HeaderMap{
            .map = MapType.init(allocator),
            .allocator = allocator,
        };
    }

    fn genEntry(self: *HeaderMap, key: String) !MapType.Entry {
        const owned_key = try std.ascii.allocLowerString(self.allocator, key);
        errdefer self.allocator.free(owned_key);

        const entry = try self.map.getOrPut(owned_key);
        if (!entry.found_existing) {
            const arrayList = try self.allocator.create(std.ArrayList(String));
            arrayList.* = std.ArrayList(String).init(self.allocator);
            entry.value_ptr.* = arrayList;
        }

        return self.map.getEntry(owned_key).?;
    }

    pub fn putManyKeys(self: *HeaderMap, keys_and_values: []const []const String) !void {
        for (keys_and_values) |kv| {
            assert(kv.len > 1);
            for (kv[1..]) |v| {
                try self.putSingle(kv[0], v);
            }
        }
    }

    pub fn putSingle(self: *HeaderMap, key: String, value: String) !void {
        const lower_key = try std.ascii.allocLowerString(self.allocator, key);
        defer self.allocator.free(lower_key);

        const entry = self.map.getEntry(lower_key) orelse try self.genEntry(key);
        try entry.value_ptr.*.append(try strings.toOwned(value, self.allocator));
    }

    pub fn getValues(self: *HeaderMap, key: String) ?[]String {
        var lower_buf: [512]u8 = undefined;
        const lower_key = std.ascii.lowerString(&lower_buf, key);

        return if (self.map.get(lower_key)) |v| v.items else null;
    }

    pub fn getValue(self: *HeaderMap, key: String, idx: usize) ?String {
        return if (self.getValues(key)) |v|
            if (v.len > idx) v[idx] else null
        else
            null;
    }

    pub fn deinit(self: *HeaderMap) void {
        for (self.map.values()) |v| {
            for (v.items) |i| {
                self.allocator.free(i);
            }
            v.clearAndFree();
            self.allocator.destroy(v);
        }
        for (self.map.keys()) |k| {
            self.allocator.free(k);
        }

        self.map.clearAndFree();
    }
};

const ErrReason = enum {
    timer,
    header_alloc,
    uri,
    open,
    send,
    finish,
    wait,
    header_scan,
    read,
};

pub fn ErrDescription(comptime reason: ErrReason) String {
    return comptime switch (reason) {
        .timer => "Failed to initialise timer",
        .header_alloc => "Could not allocate memory for storing headers",
        .uri => "Could not parse URI",
        .open => "Could not open connection",
        .send => "Could not send request",
        .finish => "Could not finish sending request",
        .wait => "Failed while waiting for response",
        .header_scan => "Failed while scanning response headers",
        .read => "Failed while reading response body",
    };
}

const SuccessResponse = struct {
    headers: HeaderMap,
    body: StringBuilder,
    code: http.Status,
};

pub const Response = union(enum) {
    failure: struct {
        base_err: anyerror,
        reason: String,
    },
    success: SuccessResponse,

    pub fn reason(self: Response, buf: []u8) !String {
        assert(buf.len >= 128);

        return switch (self) {
            .failure => |f| std.fmt.bufPrint(
                buf,
                "{s}: {s}",
                .{ f.reason, @errorName(f.base_err) },
            ),
            .success => |s| std.fmt.bufPrint(
                buf,
                "{} ({s})",
                .{ @intFromEnum(s.code), s.code.phrase() orelse "Unknown" },
            ),
        };
    }

    pub fn isSuccess(self: Response) bool {
        return switch (self) {
            .failure => false,
            .success => |s| @intFromEnum(s.code) < 400,
        };
    }
};

pub const Request = struct {
    allocator: std.mem.Allocator,

    method: String,
    url: String,
    headers: HeaderMap,

    response: Response = .{ .failure = .{
        .base_err = error.NotStarted,
        .reason = "Command execution never started",
    } },
    time_spent: u64 = 0,

    pub fn init(method: String, url: String, allocator: std.mem.Allocator) !Request {
        return Request{
            .allocator = allocator,
            .method = method,
            .url = url,
            .headers = HeaderMap.init(allocator),
        };
    }

    pub fn initResponse(self: *Request, code: http.Status) *SuccessResponse {
        self.response = Response{ .success = .{
            .body = StringBuilder.init(self.allocator),
            .headers = HeaderMap.init(self.allocator),
            .code = code,
        } };
        return &self.response.success;
    }

    pub fn isSuccess(self: Request) bool {
        return switch (self.response) {
            .failure => false,
            .success => true,
        };
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();

        switch (self.response) {
            .failure => {},
            .success => |*r| {
                r.headers.deinit();
                r.body.deinit();
            },
        }
    }
};

pub const Options = struct {
    header_buffer_size_kb: usize = 32,
    max_response_mem_mb: usize = 32,
};

pub const Client = struct {
    client: StdClient,
    allocator: std.mem.Allocator,

    pub fn do(self: *Client, request: *Request, options: Options) void {
        debug.println("Initiating {s} request to {s}", .{ request.method, request.url });

        var timer = std.time.Timer.start() catch |err| return genErrResp(
            request,
            err,
            0,
            ErrReason.timer,
        );

        const server_header_buf = self.allocator.alloc(
            u8,
            options.header_buffer_size_kb * 1024,
        ) catch |err| return genErrResp(request, err, timer.read(), ErrReason.header_alloc);
        defer self.allocator.free(server_header_buf);

        const method: http.Method = @enumFromInt(http.Method.parse(request.method));
        const uri = std.Uri.parse(request.url) catch |err| return genErrResp(
            request,
            err,
            timer.read(),
            ErrReason.uri,
        );

        var host_buffer: [256]u8 = undefined;
        const host = full_host(uri, &host_buffer) catch &host_buffer;
        var ua_buffer: [32]u8 = undefined;
        const ua = std.fmt.bufPrint(&ua_buffer, "ZingTTP/{s}", .{version}) catch &ua_buffer;

        const req_std_headers = http.Client.Request.Headers{
            .host = .{ .override = host },
            .authorization = .omit,
            .user_agent = .{ .override = ua },
            .connection = .omit,
            .accept_encoding = .{ .override = "gzip, deflate" },
        };

        debug.println("Opening connection to {s}", .{host});
        var req = StdClient.open(&self.client, method, uri, .{
            .server_header_buffer = server_header_buf,
            .redirect_behavior = StdClient.Request.RedirectBehavior.unhandled,
            .headers = req_std_headers,
        }) catch |err| return genErrResp(request, err, timer.read(), ErrReason.open);
        defer req.deinit();

        debug.println("Sending data to {s}", .{host});
        req.send() catch |err| return genErrResp(request, err, timer.read(), ErrReason.send);
        request.headers.putManyKeys(&[_][]const String{
            &[_]String{ "host", req_std_headers.host.override },
            &[_]String{ "user-agent", req_std_headers.user_agent.override },
            &[_]String{ "accept-encoding", req_std_headers.accept_encoding.override },
        }) catch |err| return genErrResp(request, err, timer.read(), ErrReason.header_alloc);
        req.finish() catch |err| return genErrResp(request, err, timer.read(), ErrReason.finish);

        debug.println("Waiting for reply from {s}", .{host});
        req.wait() catch |err| return genErrResp(request, err, timer.read(), ErrReason.wait);

        var response = request.initResponse(req.response.status);
        var header_it = req.response.iterateHeaders();
        while (header_it.next()) |h| {
            response.headers.putSingle(h.name, h.value) catch |err| return genErrResp(
                request,
                err,
                timer.read(),
                ErrReason.header_scan,
            );
        }

        const max = options.max_response_mem_mb * 1024;
        debug.println("Reading up to {} bytes from response", .{max});
        // TODO: Find a way to handle large responses, by maybe writing them to a file.

        req.reader().readAllArrayList(&response.body, max) catch |err| return genErrResp(
            request,
            err,
            timer.read(),
            ErrReason.read,
        );

        request.time_spent = timer.read();
        if (debug.isActive()) {
            const time_str = std.fmt.fmtDuration(request.time_spent);
            debug.println(
                "Finished {s} request to {s} in {s}",
                .{ request.method, request.url, time_str },
            );
        }
    }

    pub fn deinit(self: *Client) void {
        self.client.deinit();
    }
};

fn genErrResp(request: *Request, err: anyerror, elapsed: u64, comptime reason: ErrReason) void {
    const reason_str = ErrDescription(reason);
    request.response = .{ .failure = .{
        .base_err = err,
        .reason = reason_str,
    } };
    request.time_spent = elapsed;

    debug.println("Request failed: {s}", .{reason_str});
}

fn full_host(uri: std.Uri, buffer: []u8) ![]u8 {
    var stream = std.io.fixedBufferStream(buffer);
    if (uri.host) |h| {
        const h_str = switch (h) {
            inline else => |v| v,
        };
        try std.fmt.format(stream.writer(), "{s}", .{h_str});
    }
    if (uri.port) |p| {
        try std.fmt.format(stream.writer(), ":{}", .{p});
    }
    return stream.getWritten();
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const test_allocator = std.testing.allocator;

test HeaderMap {
    var header_map = HeaderMap.init(test_allocator);
    defer header_map.deinit();

    try header_map.putSingle("Header", "Value");
    try expectEqualStrings("Value", header_map.getValue("Header", 0).?);
    try expect(header_map.getValue("Header", 3) == null);

    try header_map.putSingle("Header2", "Value1");
    try header_map.putSingle("Header2", "Value2");
    try expect(header_map.getValues("Header2").?.len == 2);
    try expectEqualStrings("Value2", header_map.getValue("Header2", 1).?);

    try expect(header_map.getValues("Header 3") == null);
    try expect(header_map.getValue("Header 3", 3) == null);
}

test Client {
    var test_client = client(test_allocator);
    defer test_client.deinit();

    var req = try Request.init("GET", "http://localhost:9009", test_allocator);
    defer req.deinit();

    test_client.do(&req, .{});

    try expectEqualStrings("localhost:9009", req.headers.map.get("host").?.items[0]);
}

test "Client doesn't panic on invalid URL values" {
    const test_values = [_]String{ "", "google.com", "http::/google.com" };

    var test_client = client(test_allocator);
    defer test_client.deinit();

    inline for (test_values) |v| {
        var req = try Request.init("GET", v, test_allocator);
        defer req.deinit();

        test_client.do(&req, .{});
    }
}

test "Request deinit works" {
    var resp_headers = HeaderMap.init(test_allocator);
    try resp_headers.putSingle("Content-Type", "application/json");

    var resp_body = StringBuilder.init(test_allocator);
    try resp_body.appendSlice("hello\n");

    var req = try Request.init("GET", "http://some_site.com", test_allocator);
    try req.headers.putSingle("Content-Type", "application/json");
    req.time_spent = 128;
    req.response = .{ .success = .{
        .headers = resp_headers,
        .body = resp_body,
        .code = http.Status.ok,
    } };

    req.deinit();
    try expect(!std.testing.allocator_instance.detectLeaks());
}

test "timer works" {
    var test_client = client(test_allocator);
    defer test_client.deinit();

    var req = try Request.init("GET", "http://localhost:9009/wait", test_allocator);
    defer req.deinit();

    test_client.do(&req, .{});
    try expect(req.time_spent > 1000);
}
