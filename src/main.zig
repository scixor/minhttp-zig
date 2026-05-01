const std = @import("std");
const minhttp = @import("minhttp");
const ex = minhttp.exchange;
const rtr = minhttp.router;
const srv = minhttp.server;

fn handleIndex(init: ex.Init, _: *ex.Request, res: *ex.Response) rtr.HandlerError!void {
    std.log.info("/: GET", .{});
    try res.body_writer.write(init.alloc, "hello\n");
}

fn handleEcho(init: ex.Init, req: *ex.Request, res: *ex.Response) rtr.HandlerError!void {
    std.log.info("/echo: POST", .{});
    res.content_type = req.headers.map.get("Content-Type") orelse "text/plain";
    const body = req.body_reader.readAll(init.alloc, 1024 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BodyTooLarge, error.ReadFailed, error.EndOfStream, error.InvalidChunk => {
            res.status = 400;
            return;
        },
    };
    try res.body_writer.write(init.alloc, body);
}

fn handlePing(init: ex.Init, _: *ex.Request, res: *ex.Response) rtr.HandlerError!void {
    std.log.info("/ping: GET", .{});
    try res.body_writer.write(init.alloc, "pong\n");
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const loopback = try std.Io.net.Ip4Address.parse("127.0.0.1", 9865);

    var server = try srv.Server.init(init.io, .{
        .address = .{ .ip4 = loopback },
    });
    defer server.deinit(alloc);

    try server.router.get(alloc, "/", handleIndex);
    try server.router.get(alloc, "/ping", handlePing);
    try server.router.post(alloc, "/echo", handleEcho);

    try server.listen(alloc);
}
