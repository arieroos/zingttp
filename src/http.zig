const std = @import("std");
const http = std.http;
const StdClient = http.Client;

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
    url_alloc,
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
        .url_alloc => "Failed to allocate memory for storing the url",
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

pub const Response = union(enum) {
    failure: struct {
        base_err: anyerror,
        reason: String,
    },
    success: struct {
        headers: HeaderMap,
        body: StringBuilder,
        code: http.Status,
    },
};

pub const Request = struct {
    allocator: std.mem.Allocator,

    method: strings.AllocString,
    url: strings.AllocString,
    headers: HeaderMap,

    response: Response = .{ .failure = .{
        .base_err = error.NotStarted,
        .reason = "Command execution never started",
    } },
    time_spent: u64 = 0,

    pub fn init(method: String, url: String, allocator: std.mem.Allocator) !Request {
        return Request{
            .allocator = allocator,
            .method = try strings.AllocString.init(method, allocator),
            .url = try strings.AllocString.init(url, allocator),
            .headers = HeaderMap.init(allocator),
        };
    }

    pub fn deinit(self: *Request) void {
        self.method.deinit();
        self.url.deinit();

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

    pub fn do(self: *Client, request: *Request, options: Options) *Request {
        debug.println("Initiating {s} request to {s}", .{ request.method.value, request.url.value });

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

        const method: http.Method = @enumFromInt(http.Method.parse(request.method.value));
        const uri = std.Uri.parse(request.url.value) catch |err| return genErrResp(
            request,
            err,
            timer.read(),
            ErrReason.uri,
        );

        const host = if (!debug.isActive()) "" else if (uri.host) |h| switch (h) {
            .percent_encoded, .raw => |v| v,
        } else "";

        debug.println("Opening connection to {s}", .{host});
        var req = StdClient.open(&self.client, method, uri, .{
            .server_header_buffer = server_header_buf,
            .redirect_behavior = StdClient.Request.RedirectBehavior.unhandled,
        }) catch |err| return genErrResp(request, err, timer.read(), ErrReason.open);
        defer req.deinit();

        debug.println("Sending data to {s}", .{host});
        req.send() catch |err| return genErrResp(request, err, timer.read(), ErrReason.send);
        req.finish() catch |err| return genErrResp(request, err, timer.read(), ErrReason.finish);

        debug.println("Waiting for reply from {s}", .{host});
        req.wait() catch |err| return genErrResp(request, err, timer.read(), ErrReason.wait);

        const header_map = scanHeaders(
            server_header_buf,
            self.allocator,
        ) catch |err| return genErrResp(request, err, timer.read(), ErrReason.header_scan);

        var response_body = StringBuilder.init(self.allocator);
        const max = options.max_response_mem_mb * 1024;
        debug.println("Reading up to {} bytes from response", .{max});
        // TODO: Find a way to handle large responses, by maybe writing them to a file.

        req.reader().readAllArrayList(&response_body, max) catch |err| return genErrResp(
            request,
            err,
            timer.read(),
            ErrReason.read,
        );

        request.response = .{ .success = .{
            .headers = header_map,
            .body = response_body,
            .code = req.response.status,
        } };
        request.time_spent = timer.read();

        if (debug.isActive()) {
            const time_str = std.fmt.fmtDuration(request.time_spent);
            debug.println(
                "Finsihed {s} request to {s} in {s}",
                .{ request.method.value, request.url.value, time_str },
            );
        }
        return request;
    }

    pub fn deinit(self: *Client) void {
        self.client.deinit();
    }
};

fn genErrResp(request: *Request, err: anyerror, elapsed: u64, comptime reason: ErrReason) *Request {
    const reason_str = ErrDescription(reason);
    request.response = .{ .failure = .{
        .base_err = err,
        .reason = reason_str,
    } };
    request.time_spent = elapsed;

    debug.println("Request failed: {s}", .{reason_str});
    return request;
}

fn scanHeaders(header_buf: String, allocator: std.mem.Allocator) !HeaderMap {
    var header_map = HeaderMap.init(allocator);

    var lines = std.mem.splitSequence(u8, header_buf, "\r\n");
    _ = lines.next(); // The first line is the HTTP Status
    while (lines.next()) |line| {
        if (line.len == 0) {
            break;
        }

        var splits = std.mem.splitSequence(u8, line, ": ");
        const header_name = splits.first();
        const header_values = splits.rest();

        if (strings.iEql(header_name, "Set-Cookie")) {
            try header_map.putSingle(header_name, header_values);
        }

        var start: usize = 0;
        var quoted = false;
        for (header_values, 0..) |c, i| {
            if (c == ',' and !quoted) {
                const header_value = cleanHeaderVal(header_values[start..i]);
                if (header_value.len > 0) try header_map.putSingle(header_name, header_value);
                start = i + 1;
            }
            if (c == '"')
                quoted = !quoted and std.mem.containsAtLeastScalar(
                    u8,
                    header_values[i + 1 ..],
                    1,
                    '"',
                );
        }
        const header_value = cleanHeaderVal(header_values[start..]);
        if (header_value.len > 0) try header_map.putSingle(header_name, header_value);
    }

    return header_map;
}

fn cleanHeaderVal(h: String) String {
    var done = false;
    var p = h;
    while (!done) {
        const n = strings.trimWhitespace(
            if (p[0] == '"' and p[p.len - 1] == '"') p[1 .. p.len - 1] else p,
        );
        if (!strings.eql(n, p)) p = n else done = true;
    }
    return p;
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

    var req = try Request.init("GET", "https://jsonplaceholder.typicode.com/posts/1", test_allocator);
    var result = test_client.do(&req, .{});
    defer result.deinit();
}

test "Client doesn't panic on invalid URL values" {
    const test_values = [_]String{ "", "google.com", "http::/google.com" };

    var test_client = client(test_allocator);
    defer test_client.deinit();

    inline for (test_values) |v| {
        var req = try Request.init("GET", v, test_allocator);
        var result = test_client.do(&req, .{});
        defer result.deinit();
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

test "scanHeaders scans headers" {
    const header_str = "HTTP/1.1 201 Created\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Location: http://example.com/users/123\r\n" ++
        "X-Custom: Value 1\r\n" ++
        "x-custom: Value 2\r\n" ++
        "X-Comma-Separated: Value 1, Value 2, \"Value 3,4 and 5\"\r\n" ++
        "\r\n";

    var buf: [1024]u8 = undefined;
    std.mem.copyForwards(u8, &buf, header_str);

    var headers = try scanHeaders(&buf, test_allocator);
    defer headers.deinit();

    try expectEqualStrings("application/json", headers.getValue("Content-Type", 0).?);
    try expect(headers.getValues("Content-Type").?.len == 1);
    try expectEqualStrings("http://example.com/users/123", headers.getValue("Location", 0).?);
    try expect(headers.getValues("Location").?.len == 1);

    try expectEqualStrings("Value 1", headers.getValue("X-Custom", 0).?);
    try expectEqualStrings("Value 2", headers.getValue("X-Custom", 1).?);
    try expect(headers.getValues("X-Custom").?.len == 2);

    try expectEqualStrings("Value 1", headers.getValue("X-Comma-Separated", 0).?);
    try expectEqualStrings("Value 2", headers.getValue("X-Comma-Separated", 1).?);
    try expectEqualStrings("Value 3,4 and 5", headers.getValue("X-Comma-Separated", 2).?);
    try expect(headers.getValues("X-Comma-Separated").?.len == 3);
}
