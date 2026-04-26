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
} || Io.Cancelable;

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

    const line = request.RequestLine.parse(head) catch |err| {
        std.log.err("RequestLine.parse: {s}", .{@errorName(err)});
        return error.ParseRequestLine;
    };
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
            std.log.err("connection: {s}", .{@errorName(err)});
        };
    }

    fn handleClientInner(alloc: std.mem.Allocator, self: *Server, client: net.Stream) ConnError!void {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const req_alloc = arena_state.allocator();

        const read_buf = try alloc.alloc(u8, self.config.read_buf_size);
        defer alloc.free(read_buf);
        const write_buf = try alloc.alloc(u8, self.config.write_buf_size);
        defer alloc.free(write_buf);

        var reader = client.reader(self.io, read_buf);
        var writer = client.writer(self.io, write_buf);

        var req = try readRequest(alloc, self.config.read_buf_size, &reader);
        defer req.headers.deinit(alloc);

        const res = dispatchRequest(&self.router, &req, req_alloc);
        try rtr.writeResponse(&writer.interface, res);
        try writer.interface.flush();
    }
};
