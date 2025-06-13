const std = @import("std");
const http = std.http;

pub fn client(allocator: std.mem.Allocator) Client {
    return Client{
        .client = http.Client{ .allocator = allocator },
        .allocator = allocator,
    };
}

pub const Response = struct {
    body: std.ArrayList(u8),
    fetch_error: ?anyerror = null,
    response_code: ?http.Status = null,
};

pub const Client = struct {
    client: http.Client,
    allocator: std.mem.Allocator,

    pub fn do(self: *Client, method: []const u8, url: []const u8) Response {
        var response_body = std.ArrayList(u8).init(self.allocator);
        const response = self.client.fetch(.{
            .method = @enumFromInt(http.Method.parse(method)),
            .location = .{ .url = url },
            .response_storage = .{ .dynamic = &response_body },
        });

        var result = Response{
            .body = response_body,
        };

        if (response) |r| {
            result.response_code = r.status;
        } else |err| {
            result.fetch_error = err;
        }

        return result;
    }

    pub fn deinit(self: *Client) void {
        self.client.deinit();
    }
};

var expect = std.testing.expect;
var test_allocator = std.testing.allocator;

test Client {
    var test_client = client(test_allocator);
    defer test_client.deinit();

    var result = test_client.do("GET", "https://jsonplaceholder.typicode.com/posts/1");
    defer result.body.deinit();
}
