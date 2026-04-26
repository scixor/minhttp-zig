const std = @import("std");
const minhttp = @import("minhttp");
const rtr = minhttp.router;
const srv = minhttp.server;

fn handleIndex(_: *rtr.Request, res: *rtr.Response) rtr.HandlerError!void {
    res.body = "hello\n";
}

fn handleEcho(req: *rtr.Request, res: *rtr.Response) rtr.HandlerError!void {
    res.content_type = req.headers.map.get("Content-Type") orelse "text/plain";
    res.body = req.body;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const loopback = try std.Io.net.Ip4Address.parse("127.0.0.1", 9865);

    var server = try srv.Server.init(init.io, .{
        .address = .{ .ip4 = loopback },
    });
    defer server.deinit(alloc);

    try server.router.get(alloc, "/", handleIndex);
    try server.router.post(alloc, "/echo", handleEcho);

    try server.listen(alloc);
}
