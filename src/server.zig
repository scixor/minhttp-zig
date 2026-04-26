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

/// Returns a `Server` type bound to a comptime-known router. Dispatch is
/// resolved at compile time
pub fn Server(comptime router: rtr.Router) type {
    return ServerImpl(router);
}

fn ServerImpl(comptime router: rtr.Router) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        io: Io,
        config: Config,
        listener: net.Server,

        pub fn init(gpa: std.mem.Allocator, io: Io, config: Config) InitError!Self {
            var listener = try config.address.listen(io, .{
                .reuse_address = config.reuse_address,
            });
            errdefer listener.deinit(io);

            return .{
                .gpa = gpa,
                .io = io,
                .config = config,
                .listener = listener,
            };
        }

        pub fn deinit(self: *Self) void {
            self.listener.deinit(self.io);
        }

        pub fn listen(self: *Self) ListenError!void {
            std.log.info("listening on port {}", .{self.listener.socket.address.getPort()});

            var group: Io.Group = .init;
            while (true) {
                const client = try self.listener.accept(self.io);
                group.async(self.io, handleClient, .{ self, client });
            }
        }

        const ConnError = error{
            OutOfMemory,
            ReadFailed,
            WriteFailed,
            ParseRequestLine,
            ParseHeaders,
            ParseBody,
            BodyTooLarge,
        } || Io.Cancelable;

        /// Per-connection thing. Logs and swallows non-cancellation errors
        /// so they don't tear down the `Io.Group`. Cancellation propagates.
        fn handleClient(self: *Self, client: net.Stream) Io.Cancelable!void {
            defer client.close(self.io);
            handleClientInner(self, client) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                std.log.err("connection: {s}", .{@errorName(err)});
            };
        }

        const ParsedRequest = struct {
            line: request.RequestLine,
            headers: request.RequestHeaders,
            body: []const u8,
        };

        fn readRequest(self: *Self, reader: anytype) ConnError!ParsedRequest {
            var needed: usize = 1;
            var head: []const u8 = undefined;
            while (true) {
                // NOTE: (ง •̀_•́)ง unlike what it looks like peekGreedy does one [recv]
                // 1 is just for peekGreedy to
                head = reader.interface.peekGreedy(needed) catch |err| switch (err) {
                    error.EndOfStream, error.ReadFailed => return error.ReadFailed,
                };

                if (std.mem.indexOf(u8, head, "\r\n\r\n") != null) break;
                if (head.len == self.config.read_buf_size) return error.ParseHeaders;

                needed = head.len + 1;
            }

            const line = request.RequestLine.parse(head) catch |err| {
                std.log.err("RequestLine.parse: {s}", .{@errorName(err)});
                return error.ParseRequestLine;
            };
            var headers = request.RequestHeaders.parse(self.gpa, head[line.raw.len..]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.HeaderNoDelimiter => return error.ParseHeaders,
            };
            errdefer headers.deinit(self.gpa);

            const body_len = headers.contentLength() catch return error.ParseBody;
            const request_len = line.raw.len + headers.raw.len + 4 + body_len;
            if (request_len > self.config.read_buf_size) return error.BodyTooLarge;

            const raw = reader.interface.peekGreedy(request_len) catch |err| switch (err) {
                error.EndOfStream, error.ReadFailed => return error.ReadFailed,
            };
            const body = headers.body(raw, line) catch |err| switch (err) {
                error.InvalidContentLength, error.BodyIncomplete => return error.ParseBody,
            };
            reader.interface.tossBuffered();

            return .{
                .line = line,
                .headers = headers,
                .body = body,
            };
        }

        fn dispatchRequest(req: *rtr.Request, req_alloc: std.mem.Allocator) rtr.Response {
            var res = rtr.Response{ .alloc = req_alloc };

            if (router.dispatch(req.line.method, req.line.path)) |handler| {
                handler(req, &res) catch |err| switch (err) {
                    error.OutOfMemory, error.WriteFailed => {
                        std.log.err("handler: {s}", .{@errorName(err)});
                        return .{
                            .alloc = req_alloc,
                            .status = 500,
                            .body = "Internal Server Error\n",
                        };
                    },
                };
                return res;
            }

            res.status = 404;
            res.body = "Not Found\n";
            return res;
        }

        fn handleClientInner(self: *Self, client: net.Stream) ConnError!void {
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            const req_alloc = arena_state.allocator();

            const read_buf = try self.gpa.alloc(u8, self.config.read_buf_size);
            defer self.gpa.free(read_buf);
            const write_buf = try self.gpa.alloc(u8, self.config.write_buf_size);
            defer self.gpa.free(write_buf);

            var reader = client.reader(self.io, read_buf);
            var writer = client.writer(self.io, write_buf);

            var parsed = try readRequest(self, &reader);
            defer parsed.headers.deinit(self.gpa);

            var req = rtr.Request{
                .line = parsed.line,
                .headers = parsed.headers,
                .body = parsed.body,
            };
            const res = dispatchRequest(&req, req_alloc);
            try rtr.writeResponse(&writer.interface, res);
            try writer.interface.flush();
        }
    };
}
