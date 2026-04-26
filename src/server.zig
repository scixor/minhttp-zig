const std = @import("std");
const Io = std.Io;
const net = Io.net;

const request = @import("request.zig");
const rtr = @import("router.zig");

pub const Config = struct {
    address: net.IpAddress,
    reuse_address: bool = true,
    /// Buffer size for reading the request.
    read_buf_size: usize = 4096,
    /// Buffer size for writing the response.
    write_buf_size: usize = 4096,
    /// Idle timeout between keep-alive requests. `.none` disables timeout.
    keep_alive_timeout: Io.Timeout = .none,
};

pub const InitError = net.IpAddress.ListenError;
pub const ListenError = net.Server.AcceptError;

const ConnError = error{
    OutOfMemory,
    ReadFailed,
    WriteFailed,
    ParseRequestLine,
    ParseHeaders,
    ParseBody,
    BodyTooLarge,
    Timeout,
    PeerClosed,
} || Io.Cancelable;

fn shouldKeepAlive(req: *const rtr.Request) bool {
    const conn = req.headers.map.get("Connection") orelse return true;
    return !std.ascii.eqlIgnoreCase(conn, "close");
}

// HACK: (>_<) reaching into std.Io.Reader internals (seek/end).
// Reader has no timeout-aware peekGreedy... operateTimeout fires directly into
// buffer[0..1] then we prime seek/end so the next peekGreedy finds the byte
// already buffered and skips the blocking recv. This Breaks if Reader layout changes.
fn waitForData(io: Io, reader: *net.Stream.Reader, timeout: Io.Timeout) ConnError!void {
    var bufs: [1][]u8 = .{reader.interface.buffer[0..1]};
    const op_result = io.operateTimeout(.{ .net_read = .{
        .socket_handle = reader.stream.socket.handle,
        .data = &bufs,
    } }, timeout) catch |err| switch (err) {
        error.Timeout => return error.Timeout,
        error.Canceled => return error.Canceled,
        error.ConcurrencyUnavailable => return error.ReadFailed,
    };
    const n = op_result.net_read catch return error.ReadFailed;
    if (n == 0) return error.PeerClosed;
    reader.interface.seek = 0;
    reader.interface.end = n;
}

fn readRequest(alloc: std.mem.Allocator, read_buf_size: usize, reader: anytype) ConnError!rtr.Request {
    var needed: usize = 1;
    var head: []const u8 = undefined;
    while (true) {
        // NOTE: (ง •̀_•́)ง unlike what it looks like peekGreedy does one [recv]
        // 1 is just for peekGreedy to
        head = reader.interface.peekGreedy(needed) catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed => return error.ReadFailed,
        };
        if (std.mem.indexOf(u8, head, "\r\n\r\n") != null) break;
        if (head.len == read_buf_size) return error.ParseHeaders;
        needed = head.len + 1;
    }

    const line = request.RequestLine.parse(head) catch return error.ParseRequestLine;
    var headers = request.RequestHeaders.parse(alloc, head[line.raw.len..]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.HeaderNoDelimiter => return error.ParseHeaders,
    };
    errdefer headers.deinit(alloc);

    const body_len = headers.contentLength() catch return error.ParseBody;
    const request_len = line.raw.len + headers.raw.len + 4 + body_len;
    if (request_len > read_buf_size) return error.BodyTooLarge;

    const raw = reader.interface.peekGreedy(request_len) catch |err| switch (err) {
        error.EndOfStream, error.ReadFailed => return error.ReadFailed,
    };
    const body = headers.body(raw, line) catch |err| switch (err) {
        error.InvalidContentLength, error.BodyIncomplete => return error.ParseBody,
    };
    reader.interface.tossBuffered();

    return .{ .line = line, .headers = headers, .body = body };
}

fn dispatchRequest(router: *const rtr.Router, req: *rtr.Request, req_alloc: std.mem.Allocator) rtr.Response {
    var res = rtr.Response{ .alloc = req_alloc };

    if (router.dispatch(req.line.method, req.line.path)) |handler| {
        handler(req, &res) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => {
                std.log.err("handler: {s}", .{@errorName(err)});
                return .{ .alloc = req_alloc, .status = 500, .body = "Internal Server Error\n" };
            },
        };
        return res;
    }

    res.status = 404;
    res.body = "Not Found\n";
    return res;
}

pub const Server = struct {
    io: Io,
    config: Config,
    listener: net.Server,
    router: rtr.Router,

    pub fn init(io: Io, config: Config) InitError!Server {
        var listener = try config.address.listen(io, .{
            .reuse_address = config.reuse_address,
        });
        errdefer listener.deinit(io);
        return .{
            .io = io,
            .config = config,
            .listener = listener,
            .router = rtr.Router.init(),
        };
    }

    pub fn deinit(self: *Server, alloc: std.mem.Allocator) void {
        self.listener.deinit(self.io);
        self.router.deinit(alloc);
    }

    pub fn listen(self: *Server, alloc: std.mem.Allocator) ListenError!void {
        std.log.info("listening on port {}", .{self.listener.socket.address.getPort()});
        var group: Io.Group = .init;
        while (true) {
            const client = try self.listener.accept(self.io);
            group.async(self.io, handleClient, .{ alloc, self, client });
        }
    }

    /// Per-connection handler. Logs and swallows non-cancellation errors
    /// so they don't tear down the `Io.Group`. Cancellation propagates.
    fn handleClient(alloc: std.mem.Allocator, self: *Server, client: net.Stream) Io.Cancelable!void {
        defer client.close(self.io);
        handleClientInner(alloc, self, client) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (err == error.Timeout or err == error.PeerClosed) return;
            std.log.err("connection: {s}", .{@errorName(err)});
        };
    }

    fn handleClientInner(alloc: std.mem.Allocator, self: *Server, client: net.Stream) ConnError!void {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();

        const read_buf = try alloc.alloc(u8, self.config.read_buf_size);
        defer alloc.free(read_buf);
        const write_buf = try alloc.alloc(u8, self.config.write_buf_size);
        defer alloc.free(write_buf);

        var reader: net.Stream.Reader = client.reader(self.io, read_buf);
        var writer = client.writer(self.io, write_buf);

        while (true) {
            var req = readRequest(alloc, self.config.read_buf_size, &reader) catch |err| switch (err) {
                error.ParseRequestLine, error.ParseHeaders, error.ParseBody, error.BodyTooLarge => {
                    const bad_req: rtr.Response = .{ .alloc = arena_state.allocator(), .status = 400, .body = "Bad Request\n" };
                    rtr.writeResponse(&writer.interface, bad_req, false) catch {};
                    writer.interface.flush() catch {};
                    return;
                },
                else => |e| return e,
            };
            defer req.headers.deinit(alloc);

            const keep_alive = shouldKeepAlive(&req);
            const res = dispatchRequest(&self.router, &req, arena_state.allocator());
            try rtr.writeResponse(&writer.interface, res, keep_alive);
            try writer.interface.flush();

            if (!keep_alive) break;
            _ = arena_state.reset(.retain_capacity);
            try waitForData(self.io, &reader, self.config.keep_alive_timeout);
        }
    }
};

test "shouldKeepAlive - no Connection header returns true" {
    var headers = try request.RequestHeaders.parse(std.testing.allocator, "Host: example.com\r\n\r\n");
    defer headers.deinit(std.testing.allocator);
    const req = rtr.Request{ .line = .{ .raw = "", .path = "/", .method = .GET }, .headers = headers, .body = "" };
    try std.testing.expect(shouldKeepAlive(&req));
}

test "shouldKeepAlive - Connection: close returns false" {
    var headers = try request.RequestHeaders.parse(std.testing.allocator, "Connection: close\r\n\r\n");
    defer headers.deinit(std.testing.allocator);
    const req = rtr.Request{ .line = .{ .raw = "", .path = "/", .method = .GET }, .headers = headers, .body = "" };
    try std.testing.expect(!shouldKeepAlive(&req));
}

test "shouldKeepAlive - Connection: keep-alive returns true" {
    var headers = try request.RequestHeaders.parse(std.testing.allocator, "Connection: keep-alive\r\n\r\n");
    defer headers.deinit(std.testing.allocator);
    const req = rtr.Request{ .line = .{ .raw = "", .path = "/", .method = .GET }, .headers = headers, .body = "" };
    try std.testing.expect(shouldKeepAlive(&req));
}

test "shouldKeepAlive - case insensitive" {
    var headers = try request.RequestHeaders.parse(std.testing.allocator, "Connection: Close\r\n\r\n");
    defer headers.deinit(std.testing.allocator);
    const req = rtr.Request{ .line = .{ .raw = "", .path = "/", .method = .GET }, .headers = headers, .body = "" };
    try std.testing.expect(!shouldKeepAlive(&req));
}

// This is only for tests
const TestSocketPair = struct {
    fds: [2]std.posix.fd_t,

    fn init() !TestSocketPair {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds)) != .SUCCESS)
            return error.Unexpected;
        return .{ .fds = fds };
    }

    fn deinit(self: TestSocketPair) void {
        _ = std.posix.system.close(self.fds[0]);
        _ = std.posix.system.close(self.fds[1]);
    }

    fn reader(self: TestSocketPair, io: Io, buf: []u8) net.Stream.Reader {
        const addr: net.IpAddress = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } };
        return (net.Stream{ .socket = .{ .handle = self.fds[0], .address = addr } }).reader(io, buf);
    }

    fn write(self: TestSocketPair, data: []const u8) void {
        _ = std.posix.system.write(self.fds[1], data.ptr, data.len);
    }
};

test "waitForData - primes reader buffer when data available" {
    const pair = try TestSocketPair.init();
    defer pair.deinit();
    pair.write("hello");

    var recv_buf: [4096]u8 = undefined;
    var reader = pair.reader(std.testing.io, &recv_buf);

    try waitForData(std.testing.io, &reader, .none);
    try std.testing.expectEqual(@as(usize, 0), reader.interface.seek);
    try std.testing.expect(reader.interface.end > 0);
    try std.testing.expectEqual(@as(u8, 'h'), reader.interface.buffer[0]);
}

test "waitForData - returns Timeout when no data arrives" {
    const pair = try TestSocketPair.init();
    defer pair.deinit();

    var recv_buf: [4096]u8 = undefined;
    var reader = pair.reader(std.testing.io, &recv_buf);

    const timeout: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(10), .clock = .awake } };
    try std.testing.expectError(error.Timeout, waitForData(std.testing.io, &reader, timeout));
}

test "malformed request gets 400 response" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const addr = try net.Ip4Address.parse("127.0.0.1", 0);
    var server = try Server.init(io, .{ .address = .{ .ip4 = addr } });
    defer server.deinit(alloc);

    const pair = try TestSocketPair.init();
    defer pair.deinit();

    pair.write("GARBAGE REQUEST\r\n\r\n");

    const dummy_addr: net.IpAddress = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } };
    const client = net.Stream{ .socket = .{ .handle = pair.fds[0], .address = dummy_addr } };

    try Server.handleClientInner(alloc, &server, client);

    var resp_buf: [256]u8 = undefined;
    const rc = std.posix.system.read(pair.fds[1], &resp_buf, resp_buf.len);
    try std.testing.expect(std.posix.errno(rc) == .SUCCESS);
    try std.testing.expect(std.mem.startsWith(u8, resp_buf[0..rc], "HTTP/1.1 400"));
}
