const std = @import("std");
const Io = std.Io;
const testing = std.testing;

pub const REQ_METHOD = enum(u8) {
    GET,
    PUT,
    POST,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,
    _,

    pub const lower_names = blk: {
        const fields = @typeInfo(REQ_METHOD).@"enum".fields;
        var names: [fields.len][]const u8 = undefined;

        for (fields, 0..) |field, i| {
            var buf: [field.name.len]u8 = undefined;
            _ = std.ascii.lowerString(&buf, field.name);
            names[i] = buf[0..];
        }

        break :blk names;
    };

    pub fn fromSlice(slice: []const u8) ?REQ_METHOD {
        inline for (@typeInfo(REQ_METHOD).@"enum".fields) |field| {
            if (std.ascii.eqlIgnoreCase(slice, comptime field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }

    pub fn toSlice(method: REQ_METHOD, comptime lower: bool) []const u8 {
        return if (lower) lower_names[@intFromEnum(method)] else @tagName(method);
    }
};

pub const ParseRequestLineError = error{ NoMethod, ReqNoDelimiter };

pub const RequestLine = struct {
    raw: []const u8,
    path: []const u8,
    method: REQ_METHOD,

    pub fn parse(buf: []const u8) ParseRequestLineError!RequestLine {
        const req_line = if (std.mem.indexOf(u8, buf, "\r\n")) |end| buf[0..end] else return ParseRequestLineError.ReqNoDelimiter;
        var parts = std.mem.splitScalar(u8, req_line, ' ');

        const method = parts.next() orelse return ParseRequestLineError.NoMethod;
        const path = parts.next() orelse "/";

        const method_type = REQ_METHOD.fromSlice(method) orelse return ParseRequestLineError.NoMethod;

        return .{ .raw = req_line, .method = method_type, .path = path };
    }
};

pub const ParseHeadersError = error{HeaderNoDelimiter} || std.mem.Allocator.Error;
pub const ParseContentLengthError = error{InvalidContentLength};
pub const ParseBodyError = ParseContentLengthError || error{BodyIncomplete};

pub const RequestHeaders = struct {
    raw: []const u8,
    map: std.StringHashMapUnmanaged([]const u8),
    /// NOTE: Needs to be called after [parseRequestLine] most of the time
    pub fn parse(alloc: std.mem.Allocator, buf: []const u8) ParseHeadersError!RequestHeaders {
        const end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return ParseHeadersError.HeaderNoDelimiter;

        var map = std.StringHashMapUnmanaged([]const u8){};
        try map.ensureUnusedCapacity(alloc, 32);

        var lines = std.mem.splitSequence(u8, buf[0..end], "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOf(u8, line, ":") orelse continue;
            // parse: `key`:
            const key = line[0..colon];
            // parse: :`[whitespace]value`
            const value = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
            try map.put(alloc, key, value);
        }

        return RequestHeaders{ .raw = buf[0..end], .map = map };
    }

    pub fn deinit(self: *RequestHeaders, alloc: std.mem.Allocator) void {
        self.map.deinit(alloc);
    }

    pub fn contentLength(self: RequestHeaders) ParseContentLengthError!usize {
        const value = self.map.get("Content-Length") orelse return 0;
        return std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidContentLength;
    }

    pub fn body(self: RequestHeaders, raw: []const u8, line: RequestLine) ParseBodyError![]const u8 {
        const start = line.raw.len + self.raw.len + 4;
        const body_len = try self.contentLength();
        const end = start + body_len;

        if (raw.len < end) return error.BodyIncomplete;
        return raw[start..end];
    }
};

test "RequestLine.parse parses GET" {
    const req = "GET /index.html HTTP/1.1\r\n";
    const line = try RequestLine.parse(req);
    try testing.expectEqual(REQ_METHOD.GET, line.method);
    try testing.expectEqualStrings("/index.html", line.path);
    try testing.expectEqualStrings("GET /index.html HTTP/1.1", line.raw);
}

test "RequestLine.parse - other methods" {
    const cases = .{
        .{ "POST /api HTTP/1.1\r\n", REQ_METHOD.POST },
        .{ "PUT /res HTTP/1.1\r\n", REQ_METHOD.PUT },
        .{ "DELETE /res HTTP/1.1\r\n", REQ_METHOD.DELETE },
        .{ "PATCH /res HTTP/1.1\r\n", REQ_METHOD.PATCH },
    };
    inline for (cases) |case| {
        const line = try RequestLine.parse(case[0]);
        try testing.expectEqual(case[1], line.method);
    }
}

test "RequestLine.parse - case insensitive method" {
    const line = try RequestLine.parse("post /submit HTTP/1.1\r\n");
    try testing.expectEqual(REQ_METHOD.POST, line.method);
}

test "RequestLine.parse - missing CRLF returns error" {
    try testing.expectError(error.ReqNoDelimiter, RequestLine.parse("GET /index.html HTTP/1.1"));
}

test "RequestLine.parse - unknown method throws" {
    try testing.expectError(ParseRequestLineError.NoMethod, RequestLine.parse("BREW /coffee HTTP/1.1\r\n"));
}

test "RequestHeaders.parse - single header" {
    const buf = "Host: example.com\r\n\r\n";
    var map = try RequestHeaders.parse(testing.allocator, buf);
    defer map.deinit(testing.allocator);
    try testing.expectEqualStrings("example.com", map.map.get("Host").?);
}

test "RequestHeaders.parse - multiple headers" {
    const buf = "Host: example.com\r\nContent-Type: text/html\r\n\r\n";
    var map = try RequestHeaders.parse(testing.allocator, buf);
    defer map.deinit(testing.allocator);
    try testing.expectEqualStrings("example.com", map.map.get("Host").?);
    try testing.expectEqualStrings("text/html", map.map.get("Content-Type").?);
}

test "RequestHeaders.parse - trims whitespace from values" {
    const buf = "X-Header:   spaced value   \r\n\r\n";
    var map = try RequestHeaders.parse(testing.allocator, buf);
    defer map.deinit(testing.allocator);
    try testing.expectEqualStrings("spaced value", map.map.get("X-Header").?);
}

test "RequestHeaders.parse - missing double CRLF returns error" {
    try testing.expectError(error.HeaderNoDelimiter, RequestHeaders.parse(testing.allocator, "Host: example.com\r\n"));
}

test "RequestHeaders.contentLength - missing header returns zero" {
    var headers = try RequestHeaders.parse(testing.allocator, "Host: example.com\r\n\r\n");
    defer headers.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), try headers.contentLength());
}

test "RequestHeaders.contentLength - invalid header returns error" {
    var headers = try RequestHeaders.parse(testing.allocator, "Content-Length: nope\r\n\r\n");
    defer headers.deinit(testing.allocator);
    try testing.expectError(error.InvalidContentLength, headers.contentLength());
}

test "full request - request line then headers" {
    const buf = "GET /index.html HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n";
    const line = try RequestLine.parse(buf);
    var headers = try RequestHeaders.parse(testing.allocator, buf[line.raw.len..]);
    defer headers.deinit(testing.allocator);
    try testing.expectEqual(REQ_METHOD.GET, line.method);
    try testing.expectEqualStrings("/index.html", line.path);
    try testing.expectEqualStrings("example.com", headers.map.get("Host").?);
    try testing.expectEqualStrings("*/*", headers.map.get("Accept").?);
}

test "full request - body" {
    const buf = "POST /echo HTTP/1.1\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello";
    const line = try RequestLine.parse(buf);
    var headers = try RequestHeaders.parse(testing.allocator, buf[line.raw.len..]);
    defer headers.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), try headers.contentLength());
    try testing.expectEqualStrings("hello", try headers.body(buf, line));
}

test "full request - incomplete body returns error" {
    const buf = "POST /echo HTTP/1.1\r\nContent-Length: 5\r\n\r\nhe";
    const line = try RequestLine.parse(buf);
    var headers = try RequestHeaders.parse(testing.allocator, buf[line.raw.len..]);
    defer headers.deinit(testing.allocator);

    try testing.expectError(error.BodyIncomplete, headers.body(buf, line));
}
