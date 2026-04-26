const std = @import("std");
const zig_echo = @import("minhttp");
const rtr = zig_echo.router;
const srv = zig_echo.server;

fn handleIndex(_: *rtr.Request, res: *rtr.Response) rtr.HandlerError!void {
    res.body = "hello\n";
}

fn handleEcho(req: *rtr.Request, res: *rtr.Response) rtr.HandlerError!void {
    res.content_type = req.headers.map.get("Content-Type") orelse "text/plain";
    res.body = req.body;
}

const router: rtr.Router = .{
    .get = &.{
        .{ .path = "/", .handler = handleIndex },
    },
    .post = &.{
        .{ .path = "/echo", .handler = handleEcho },
    },
};

pub fn main(init: std.process.Init) !void {
    const loopback = try std.Io.net.Ip4Address.parse("127.0.0.1", 9865);

    var server = try srv.Server(router).init(init.gpa, init.io, .{
        .address = .{ .ip4 = loopback },
    });
    defer server.deinit();

    try server.listen();
}
