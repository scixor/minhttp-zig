const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const request = @import("request.zig");

// Readers

pub const BodyReadError = Io.Reader.Error || error{InvalidChunk};
pub const BodyReadAllError = BodyReadError || std.mem.Allocator.Error || error{BodyTooLarge};

const FixedReader = struct {
    reader: *Io.Reader,
    remaining: usize,

    fn read(self: *FixedReader, buf: []u8) BodyReadError!usize {
        if (self.remaining == 0) return 0;

        const n = @min(self.remaining, buf.len);
        const got = try self.reader.readSliceShort(buf[0..n]);
        if (got == 0) return error.EndOfStream;
        self.remaining -= got;
        return got;
    }

    fn readAll(self: *FixedReader, alloc: std.mem.Allocator) BodyReadAllError![]u8 {
        const slice = try self.reader.readAlloc(alloc, self.remaining);
        self.remaining = 0;
        return slice;
    }

    fn discardAll(self: *FixedReader) BodyReadError!void {
        try self.reader.discardAll(self.remaining);
        self.remaining = 0;
    }
};

/// Parses through and returns the chunk
///
/// 4\r\n
/// Wiki\r\n <- Chunk 1
/// 5\r\n
/// pedia\r\n
/// 0\r\n
/// \r\n
const ChunkedReader = struct {
    reader: *Io.Reader,
    remaining: usize = 0,
    done: bool = false,

    fn read(self: *ChunkedReader, buf: []u8) BodyReadError!usize {
        if (buf.len == 0 or self.done) return 0;

        if (self.remaining == 0) {
            const line = try self.readLine();

            const size_part = line[0 .. std.mem.indexOfScalar(u8, line, ';') orelse line.len];
            self.remaining = std.fmt.parseUnsigned(usize, size_part, 16) catch {
                return error.InvalidChunk;
            };

            if (self.remaining == 0) {
                try self.readFinalCrlf();
                self.done = true;
                return 0;
            }
        }

        const n = @min(buf.len, self.remaining);
        const got = try self.reader.readSliceShort(buf[0..n]);
        if (got == 0) return error.EndOfStream;

        self.remaining -= got;
        if (self.remaining == 0) try self.readFinalCrlf();

        return got;
    }

    fn readLine(self: *ChunkedReader) BodyReadError![]const u8 {
        const line = (self.reader.takeDelimiter('\n') catch {
            return error.InvalidChunk;
        }) orelse return error.EndOfStream;

        if (line.len == 0 or line[line.len - 1] != '\r') return error.InvalidChunk;
        return line[0 .. line.len - 1];
    }

    fn readFinalCrlf(self: *ChunkedReader) BodyReadError!void {
        const crlf = try self.reader.take(2);
        if (!std.mem.eql(u8, crlf, "\r\n")) return error.InvalidChunk;
    }
};

pub const BodyReader = struct {
    impl: Impl,

    pub const Kind = enum { fixed, chunked, empty };
    const Impl = union(Kind) { fixed: FixedReader, chunked: ChunkedReader, empty: void };

    pub fn fixed(reader: *Io.Reader, len: usize) BodyReader {
        return .{ .impl = .{ .fixed = .{ .reader = reader, .remaining = len } } };
    }

    pub fn chunked(reader: *Io.Reader) BodyReader {
        return .{ .impl = .{ .chunked = .{ .reader = reader } } };
    }

    pub fn empty() BodyReader {
        return .{ .impl = .empty };
    }

    pub fn read(self: *BodyReader, buf: []u8) BodyReadError!usize {
        return switch (self.impl) {
            .fixed => |*r| r.read(buf),
            .chunked => |*r| r.read(buf),
            .empty => 0,
        };
    }

    pub fn readAll(self: *BodyReader, alloc: std.mem.Allocator, max_size: usize) BodyReadAllError![]u8 {
        if (self.impl == .fixed) {
            const r = &self.impl.fixed;
            if (r.remaining > max_size) return error.BodyTooLarge;
            return r.readAll(alloc);
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try self.read(&buf);
            if (n == 0) break;
            if (out.items.len + n > max_size) return error.BodyTooLarge;
            try out.appendSlice(alloc, buf[0..n]);
        }

        return out.toOwnedSlice(alloc);
    }

    pub fn discardAll(self: *BodyReader, max_size: usize) (BodyReadError || error{BodyTooLarge})!void {
        if (self.impl == .fixed) {
            const r = &self.impl.fixed;
            if (r.remaining > max_size) return error.BodyTooLarge;
            return r.discardAll();
        }

        var total: usize = 0;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try self.read(&buf);
            if (n == 0) return;
            total += n;
            if (total > max_size) return error.BodyTooLarge;
        }
    }
};

// Writers
pub const FixedWriter = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *FixedWriter, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }
};

const ChunkedWriter = struct {
    chunks: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *ChunkedWriter, alloc: std.mem.Allocator) void {
        for (self.chunks.items) |c| alloc.free(c);
        self.chunks.deinit(alloc);
    }
};

pub const BodyWriter = struct {
    impl: Impl = .{ .fixed = .{} },

    pub const Kind = enum { fixed, chunked };
    const Impl = union(Kind) { fixed: FixedWriter, chunked: ChunkedWriter };

    pub fn deinit(self: *BodyWriter, alloc: std.mem.Allocator) void {
        switch (self.impl) {
            inline else => |*w| w.deinit(alloc),
        }
    }

    /// Append bytes to fixed-length body. Produces Content-Length response.
    pub fn write(self: *BodyWriter, alloc: std.mem.Allocator, data: []const u8) error{OutOfMemory}!void {
        try self.impl.fixed.buf.appendSlice(alloc, data);
    }

    /// Append a discrete chunk. Produces Transfer-Encoding: chunked response.
    pub fn chunk(self: *BodyWriter, alloc: std.mem.Allocator, data: []const u8) error{OutOfMemory}!void {
        if (self.impl == .fixed) self.impl = .{ .chunked = .{} };
        const owned = try alloc.dupe(u8, data);
        try self.impl.chunked.chunks.append(alloc, owned);
    }
};

pub const Init = struct {
    io: Io,
    alloc: std.mem.Allocator,
};

pub const Request = struct {
    line: request.RequestLine,
    headers: request.RequestHeaders,
    body_reader: BodyReader,
};

pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "text/plain",
    body_writer: BodyWriter = .{},
};

// tests
test "FixedReader reads exact body and leaves following bytes" {
    var io_reader: Io.Reader = .fixed("helloNEXT");
    var fixed = FixedReader{ .reader = &io_reader, .remaining = 5 };

    var buf: [3]u8 = undefined;

    const n1 = try fixed.read(&buf);
    try testing.expectEqual(@as(usize, 3), n1);
    try testing.expectEqualStrings("hel", buf[0..n1]);

    const n2 = try fixed.read(&buf);
    try testing.expectEqual(@as(usize, 2), n2);
    try testing.expectEqualStrings("lo", buf[0..n2]);

    try testing.expectEqual(@as(usize, 0), try fixed.read(&buf));
    try testing.expectEqualStrings("NEXT", try io_reader.take(4));
}

test "BodyReader reads fixed body" {
    var io_reader: Io.Reader = .fixed("hello");
    var body_reader = BodyReader.fixed(&io_reader, 5);

    const body = try body_reader.readAll(testing.allocator, 16);
    defer testing.allocator.free(body);

    try testing.expectEqualStrings("hello", body);
}

test "ChunkedReader reads chunks and leaves following bytes" {
    var io_reader: Io.Reader = .fixed("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\nNEXT");
    var chunked = ChunkedReader{ .reader = &io_reader };

    var buf: [16]u8 = undefined;

    const n1 = try chunked.read(buf[0..4]);
    try testing.expectEqual(@as(usize, 4), n1);
    try testing.expectEqualStrings("Wiki", buf[0..n1]);

    const n2 = try chunked.read(&buf);
    try testing.expectEqual(@as(usize, 5), n2);
    try testing.expectEqualStrings("pedia", buf[0..n2]);

    try testing.expectEqual(@as(usize, 0), try chunked.read(&buf));
    try testing.expectEqualStrings("NEXT", try io_reader.take(4));
}

test "BodyReader reads chunked body" {
    var io_reader: Io.Reader = .fixed("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n");
    var body_reader = BodyReader.chunked(&io_reader);

    const body = try body_reader.readAll(testing.allocator, 16);
    defer testing.allocator.free(body);

    try testing.expectEqualStrings("Wikipedia", body);
}

test "BodyReader enforces max body size" {
    var io_reader: Io.Reader = .fixed("hello");
    var body_reader = BodyReader.fixed(&io_reader, 5);

    try testing.expectError(error.BodyTooLarge, body_reader.readAll(testing.allocator, 4));
}

test "BodyReader discards unread body" {
    var io_reader: Io.Reader = .fixed("helloNEXT");
    var body_reader = BodyReader.fixed(&io_reader, 5);

    try body_reader.discardAll(8);
    try testing.expectEqualStrings("NEXT", try io_reader.take(4));
}

test "ChunkedReader rejects invalid chunk size" {
    var io_reader: Io.Reader = .fixed("x\r\nhello\r\n0\r\n\r\n");
    var chunked = ChunkedReader{ .reader = &io_reader };

    var buf: [8]u8 = undefined;
    try testing.expectError(error.InvalidChunk, chunked.read(&buf));
}
