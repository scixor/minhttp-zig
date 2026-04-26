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
    get_routes: std.ArrayListUnmanaged(Route),
    post_routes: std.ArrayListUnmanaged(Route),
    put_routes: std.ArrayListUnmanaged(Route),
    delete_routes: std.ArrayListUnmanaged(Route),
    patch_routes: std.ArrayListUnmanaged(Route),

    pub fn init() Router {
        return .{
            .get_routes = .empty,
            .post_routes = .empty,
            .put_routes = .empty,
            .delete_routes = .empty,
            .patch_routes = .empty,
        };
    }

    pub fn deinit(self: *Router, alloc: std.mem.Allocator) void {
        self.get_routes.deinit(alloc);
        self.post_routes.deinit(alloc);
        self.put_routes.deinit(alloc);
        self.delete_routes.deinit(alloc);
        self.patch_routes.deinit(alloc);
    }

    pub fn get(self: *Router, alloc: std.mem.Allocator, path: []const u8, handler: HandlerFn) !void {
        try self.get_routes.append(alloc, .{ .path = path, .handler = handler });
    }

    pub fn post(self: *Router, alloc: std.mem.Allocator, path: []const u8, handler: HandlerFn) !void {
        try self.post_routes.append(alloc, .{ .path = path, .handler = handler });
    }

    pub fn put(self: *Router, alloc: std.mem.Allocator, path: []const u8, handler: HandlerFn) !void {
        try self.put_routes.append(alloc, .{ .path = path, .handler = handler });
    }

    pub fn delete(self: *Router, alloc: std.mem.Allocator, path: []const u8, handler: HandlerFn) !void {
        try self.delete_routes.append(alloc, .{ .path = path, .handler = handler });
    }

    pub fn patch(self: *Router, alloc: std.mem.Allocator, path: []const u8, handler: HandlerFn) !void {
        try self.patch_routes.append(alloc, .{ .path = path, .handler = handler });
    }

    pub fn dispatch(self: *const Router, method: request.REQ_METHOD, path: []const u8) ?HandlerFn {
        const routes = switch (method) {
            .GET => self.get_routes.items,
            .POST => self.post_routes.items,
            .PUT => self.put_routes.items,
            .DELETE => self.delete_routes.items,
            .PATCH => self.patch_routes.items,
            else => return null,
        };

        for (routes) |route| {
            if (std.mem.eql(u8, route.path, path)) return route.handler;
        }

        return null;
    }
};

/// Writes a full HTTP/1.1 response to `writer` from the given `Response`.
/// Content-Length is computed from `res.body.len`.
pub fn writeResponse(writer: *std.Io.Writer, res: Response, keep_alive: bool) std.Io.Writer.Error!void {
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
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n",
        .{ res.status, reason, res.content_type, res.body.len, if (keep_alive) "keep-alive" else "close" },
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
    var router = Router.init();
    defer router.deinit(testing.allocator);
    try router.get(testing.allocator, "/a", TestHandlers.a);
    try router.get(testing.allocator, "/b", TestHandlers.b);
    try testing.expectEqual(@as(?HandlerFn, TestHandlers.a), router.dispatch(.GET, "/a"));
    try testing.expectEqual(@as(?HandlerFn, TestHandlers.b), router.dispatch(.GET, "/b"));
}

test "Router.dispatch - unknown path returns null" {
    var router = Router.init();
    defer router.deinit(testing.allocator);
    try router.get(testing.allocator, "/a", TestHandlers.a);
    try testing.expectEqual(@as(?HandlerFn, null), router.dispatch(.GET, "/missing"));
}

test "Router.dispatch - method mismatch returns null" {
    var router = Router.init();
    defer router.deinit(testing.allocator);
    try router.get(testing.allocator, "/a", TestHandlers.a);
    try testing.expectEqual(@as(?HandlerFn, null), router.dispatch(.POST, "/a"));
}

test "Router.dispatch - per-method tables are independent" {
    var router = Router.init();
    defer router.deinit(testing.allocator);
    try router.get(testing.allocator, "/x", TestHandlers.a);
    try router.post(testing.allocator, "/x", TestHandlers.b);
    try testing.expectEqual(@as(?HandlerFn, TestHandlers.a), router.dispatch(.GET, "/x"));
    try testing.expectEqual(@as(?HandlerFn, TestHandlers.b), router.dispatch(.POST, "/x"));
}

test "Router.dispatch - empty router returns null" {
    var router = Router.init();
    defer router.deinit(testing.allocator);
    try testing.expectEqual(@as(?HandlerFn, null), router.dispatch(.GET, "/"));
}

test "Router.dispatch - unsupported method returns null" {
    var router = Router.init();
    defer router.deinit(testing.allocator);
    try router.get(testing.allocator, "/a", TestHandlers.a);
    try testing.expectEqual(@as(?HandlerFn, null), router.dispatch(.OPTIONS, "/a"));
}

test "writeResponse - 200 with body" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeResponse(&w, .{
        .alloc = testing.allocator,
        .status = 200,
        .body = "hi",
    }, false);
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
    }, false);
    const expected =
        "HTTP/1.1 404 Not Found\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 0\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    try testing.expectEqualStrings(expected, w.buffered());
}

test "writeResponse - keep-alive header" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeResponse(&w, .{
        .alloc = testing.allocator,
        .status = 200,
        .body = "hi",
    }, true);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "Connection: keep-alive\r\n") != null);
}

test "writeResponse - custom content_type" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeResponse(&w, .{
        .alloc = testing.allocator,
        .content_type = "application/json",
        .body = "{}",
    }, false);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "Content-Type: application/json\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "Content-Length: 2\r\n") != null);
}
