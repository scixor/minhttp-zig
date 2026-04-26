const std = @import("std");
const testing = std.testing;
const request = @import("request.zig");

/// Errors a handler is allowed to return. Keep this tight -- anything broader
/// should be handled inside the handler. `OutOfMemory` covers `res.alloc`
/// failures; `WriteFailed` is reserved for handlers that stream directly.
pub const HandlerError = error{
    OutOfMemory,
    WriteFailed,
};

pub const Request = struct {
    line: request.RequestLine,
    headers: request.RequestHeaders,
    body: []const u8,
};

pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "text/plain",
    body: []const u8 = "",
    alloc: std.mem.Allocator,
};

pub const HandlerFn = *const fn (req: *Request, res: *Response) HandlerError!void;

pub const Route = struct {
    path: []const u8,
    handler: HandlerFn,
};

pub const Router = struct {
    get: []const Route = &.{},
    post: []const Route = &.{},
    put: []const Route = &.{},
    delete: []const Route = &.{},
    patch: []const Route = &.{},

    pub fn dispatch(
        self: Router,
        method: request.REQ_METHOD,
        path: []const u8,
    ) ?HandlerFn {
        const routes = switch (method) {
            .GET => self.get,
            .POST => self.post,
            .PUT => self.put,
            .DELETE => self.delete,
            .PATCH => self.patch,
            else => return null,
        };

        for (routes) |route| {
            if (std.mem.eql(u8, route.path, path)) {
                return route.handler;
            }
        }

        return null;
    }
};

/// Writes a full HTTP/1.1 response to `writer` from the given `Response`.
/// Content-Length is computed from `res.body.len`.
pub fn writeResponse(writer: *std.Io.Writer, res: Response) std.Io.Writer.Error!void {
    const reason = switch (res.status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        else => "Unknown",
    };
    try writer.print(
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ res.status, reason, res.content_type, res.body.len },
    );
    try writer.writeAll(res.body);
}

const TestHandlers = struct {
    fn a(_: *Request, res: *Response) HandlerError!void {
        res.body = "A";
    }

    fn b(_: *Request, res: *Response) HandlerError!void {
        res.body = "B";
    }
};

test "Router.dispatch - exact match returns handler" {
    const router: Router = .{
        .get = &.{
            .{ .path = "/a", .handler = TestHandlers.a },
            .{ .path = "/b", .handler = TestHandlers.b },
        },
    };
    try testing.expectEqual(@as(?HandlerFn, TestHandlers.a), router.dispatch(.GET, "/a"));
    try testing.expectEqual(@as(?HandlerFn, TestHandlers.b), router.dispatch(.GET, "/b"));
}

test "Router.dispatch - unknown path returns null" {
    const router: Router = .{
        .get = &.{.{ .path = "/a", .handler = TestHandlers.a }},
    };
    try testing.expectEqual(@as(?HandlerFn, null), router.dispatch(.GET, "/missing"));
}

test "Router.dispatch - method mismatch returns null" {
    const router: Router = .{
        .get = &.{.{ .path = "/a", .handler = TestHandlers.a }},
    };
    try testing.expectEqual(@as(?HandlerFn, null), router.dispatch(.POST, "/a"));
}

test "Router.dispatch - per-method tables are independent" {
    const router: Router = .{
        .get = &.{.{ .path = "/x", .handler = TestHandlers.a }},
        .post = &.{.{ .path = "/x", .handler = TestHandlers.b }},
    };
    try testing.expectEqual(@as(?HandlerFn, TestHandlers.a), router.dispatch(.GET, "/x"));
    try testing.expectEqual(@as(?HandlerFn, TestHandlers.b), router.dispatch(.POST, "/x"));
}

test "Router.dispatch - empty router returns null" {
    const router: Router = .{};
    try testing.expectEqual(@as(?HandlerFn, null), router.dispatch(.GET, "/"));
}

test "Router.dispatch - unsupported method returns null" {
    const router: Router = .{
        .get = &.{.{ .path = "/a", .handler = TestHandlers.a }},
    };
    try testing.expectEqual(@as(?HandlerFn, null), router.dispatch(.OPTIONS, "/a"));
}

test "writeResponse - 200 with body" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeResponse(&w, .{
        .alloc = testing.allocator,
        .status = 200,
        .body = "hi",
    });
    const expected =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 2\r\n" ++
        "Connection: close\r\n" ++
        "\r\nhi";
    try testing.expectEqualStrings(expected, w.buffered());
}

test "writeResponse - 404 empty body" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeResponse(&w, .{
        .alloc = testing.allocator,
        .status = 404,
        .body = "",
    });
    const expected =
        "HTTP/1.1 404 Not Found\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 0\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    try testing.expectEqualStrings(expected, w.buffered());
}

test "writeResponse - custom content_type" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeResponse(&w, .{
        .alloc = testing.allocator,
        .content_type = "application/json",
        .body = "{}",
    });
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "Content-Type: application/json\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "Content-Length: 2\r\n") != null);
}
