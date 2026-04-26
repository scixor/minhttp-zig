# minhttp-zig

A small HTTP/1.1 server experiment in Zig, built with the newer `std.Io` pieces. WIP, tiny, and intentionally simple. (⌐■_■)

This repo is mostly about learning, poking at Zig's IO model, and building up a basic server one clean piece at a time.

- HTTP/1.1
- small codebase
- low ceremony (or high depends on the angle)
- latest-ish Zig

## little peek

handlers:

```zig
fn handleIndex(_: *rtr.Request, res: *rtr.Response) rtr.HandlerError!void {
    res.body = "hello\n";
}

fn handleEcho(req: *rtr.Request, res: *rtr.Response) rtr.HandlerError!void {
    res.content_type = req.headers.map.get("Content-Type") orelse "text/plain";
    res.body = req.body;
}
```

server setup:

```zig
var server = try srv.Server.init(init.io, .{
    .address = .{ .ip4 = loopback },
});
defer server.deinit(alloc);

try server.router.get(alloc, "/", handleIndex);
try server.router.post(alloc, "/echo", handleEcho);

try server.listen(alloc);
```

keep-alive with idle timeout:

```zig
var server = try srv.Server.init(init.io, .{
    .address = .{ .ip4 = loopback },
    .keep_alive_timeout = .{ .duration = .{ .raw = Io.Duration.fromSeconds(30), .clock = .awake } },
});
```

Tiny, direct.

## run

```bash
zig build run --release=fast
```

## dev

```bash
zig build test
zig build check
```

## zig

```text
0.17.0-dev.76+ff612334f
```

More to come c[_]
