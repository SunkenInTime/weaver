const std = @import("std");
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("winhttp.h");
});

pub const timeout_ms: c_int = 15_000;
pub const response_cap_bytes: usize = 5 * 1024 * 1024;

pub const Method = enum { get, post };
pub const Failure = enum { none, invalid_url, request_failed, timed_out, response_too_large };

pub const ParsedUrl = struct {
    declared_host: []const u8,
    connection_host: []const u8,
    path: []const u8,
    port: u16,
};

pub const Request = struct {
    method: Method = .get,
    url: []const u8 = &.{},
    headers: []const u8 = &.{},
    body: []const u8 = &.{},

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        if (self.url.len > 0) allocator.free(self.url);
        if (self.headers.len > 0) allocator.free(self.headers);
        if (self.body.len > 0) allocator.free(self.body);
        self.* = .{};
    }
};

pub const Result = struct {
    status: u16 = 0,
    body: ?[]u8 = null,
    failure: Failure = .none,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.body) |bytes| allocator.free(bytes);
        self.* = .{};
    }
};

/// Parse only the URL shape the public capability admits. Keeping host
/// extraction here and in the CLI intentionally boring makes the runtime's
/// authoritative exact-host check auditable instead of delegating policy to
/// redirects or proxy normalization.
pub fn parseHttpsUrl(url: []const u8) !ParsedUrl {
    const prefix = "https://";
    if (url.len <= prefix.len or !std.ascii.startsWithIgnoreCase(url, prefix)) return error.HttpsRequired;
    const rest = url[prefix.len..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidUrl;
    var connection_host = authority;
    var port: u16 = 443;
    if (authority[0] == '[') {
        const closing = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidUrl;
        connection_host = authority[1..closing];
        if (closing + 1 < authority.len) {
            if (authority[closing + 1] != ':') return error.InvalidUrl;
            port = std.fmt.parseInt(u16, authority[closing + 2 ..], 10) catch return error.InvalidUrl;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, authority[0..colon], ':') != null) return error.InvalidUrl;
        connection_host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.InvalidUrl;
    }
    if (connection_host.len == 0) return error.InvalidUrl;
    const suffix = rest[authority_end..];
    const path = if (suffix.len == 0) "/" else if (suffix[0] == '/') suffix else suffix;
    return .{ .declared_host = authority, .connection_host = connection_host, .path = path, .port = port };
}

pub fn originDeclared(origins: []const []const u8, host: []const u8) bool {
    for (origins) |origin| if (std.ascii.eqlIgnoreCase(origin, host)) return true;
    return false;
}

/// WinHTTP is already the fork's proven Windows HTTPS substrate. Requests run
/// only on bridge workers; automatic redirects are disabled so a response can
/// never cross the manifest's host boundary behind the policy check.
pub fn perform(request: *const Request, allocator: std.mem.Allocator) Result {
    return performFallible(request, allocator) catch |err| .{ .failure = switch (err) {
        error.HttpsRequired, error.InvalidUrl => .invalid_url,
        error.ResponseTooLarge => .response_too_large,
        error.TimedOut => .timed_out,
        else => .request_failed,
    } };
}

fn performFallible(request: *const Request, allocator: std.mem.Allocator) !Result {
    const deadline_ms = win.GetTickCount64() + @as(u64, @intCast(timeout_ms));
    const parsed = try parseHttpsUrl(request.url);
    const agent = std.unicode.utf8ToUtf16LeAllocZ(allocator, "weaver-widget/0.2") catch return error.OutOfMemory;
    defer allocator.free(agent);
    const host = std.unicode.utf8ToUtf16LeAllocZ(allocator, parsed.connection_host) catch return error.OutOfMemory;
    defer allocator.free(host);
    var path_bytes: []const u8 = parsed.path;
    var prefixed_path: ?[]u8 = null;
    if (path_bytes.len > 0 and path_bytes[0] != '/') {
        prefixed_path = std.fmt.allocPrint(allocator, "/{s}", .{path_bytes}) catch return error.OutOfMemory;
        path_bytes = prefixed_path.?;
    }
    defer if (prefixed_path) |bytes| allocator.free(bytes);
    const path = std.unicode.utf8ToUtf16LeAllocZ(allocator, path_bytes) catch return error.OutOfMemory;
    defer allocator.free(path);
    const method = std.unicode.utf8ToUtf16LeAllocZ(allocator, if (request.method == .post) "POST" else "GET") catch return error.OutOfMemory;
    defer allocator.free(method);

    const session = win.WinHttpOpen(agent.ptr, win.WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, null, null, 0) orelse return mapLastError();
    defer _ = win.WinHttpCloseHandle(session);
    try applyRemainingTimeout(session, deadline_ms);
    const connection = win.WinHttpConnect(session, host.ptr, parsed.port, 0) orelse return mapLastError();
    defer _ = win.WinHttpCloseHandle(connection);
    const handle = win.WinHttpOpenRequest(connection, method.ptr, path.ptr, null, null, null, win.WINHTTP_FLAG_SECURE) orelse return mapLastError();
    defer _ = win.WinHttpCloseHandle(handle);
    var disabled: win.DWORD = win.WINHTTP_DISABLE_REDIRECTS;
    if (win.WinHttpSetOption(handle, win.WINHTTP_OPTION_DISABLE_FEATURE, &disabled, @sizeOf(win.DWORD)) == 0) return mapLastError();
    if (request.headers.len > 0) {
        const headers = std.unicode.utf8ToUtf16LeAllocZ(allocator, request.headers) catch return error.OutOfMemory;
        defer allocator.free(headers);
        const header_flags: win.DWORD = 0x20000000 | 0x80000000; // ADD | REPLACE; translate-c types the high-bit macro as signed.
        if (win.WinHttpAddRequestHeaders(handle, headers.ptr, @intCast(headers.len), header_flags) == 0) return mapLastError();
    }
    const payload = request.body;
    const payload_pointer: win.LPVOID = if (payload.len == 0) win.WINHTTP_NO_REQUEST_DATA else @ptrCast(@constCast(payload.ptr));
    try applyRemainingTimeout(handle, deadline_ms);
    if (win.WinHttpSendRequest(handle, null, 0, payload_pointer, @intCast(payload.len), @intCast(payload.len), 0) == 0) return mapLastError();
    try applyRemainingTimeout(handle, deadline_ms);
    if (win.WinHttpReceiveResponse(handle, null) == 0) return mapLastError();
    var status: win.DWORD = 0;
    var status_size: win.DWORD = @sizeOf(win.DWORD);
    if (win.WinHttpQueryHeaders(handle, win.WINHTTP_QUERY_STATUS_CODE | win.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null) == 0) return mapLastError();
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    while (true) {
        try applyRemainingTimeout(handle, deadline_ms);
        var available: win.DWORD = 0;
        if (win.WinHttpQueryDataAvailable(handle, &available) == 0) return mapLastError();
        if (available == 0) break;
        if (body.items.len + available > response_cap_bytes) return error.ResponseTooLarge;
        const start = body.items.len;
        try body.resize(allocator, start + available);
        var read: win.DWORD = 0;
        if (win.WinHttpReadData(handle, body.items[start..].ptr, available, &read) == 0) return mapLastError();
        body.shrinkRetainingCapacity(start + read);
    }
    return .{ .status = @intCast(status), .body = try body.toOwnedSlice(allocator) };
}

fn applyRemainingTimeout(handle: win.HINTERNET, deadline_ms: u64) !void {
    const now = win.GetTickCount64();
    if (now >= deadline_ms) return error.TimedOut;
    const remaining: c_int = @intCast(@min(deadline_ms - now, @as(u64, @intCast(std.math.maxInt(c_int)))));
    if (win.WinHttpSetTimeouts(handle, remaining, remaining, remaining, remaining) == 0) return mapLastError();
}

fn mapLastError() error{TimedOut, RequestFailed} {
    return if (win.GetLastError() == win.ERROR_WINHTTP_TIMEOUT) error.TimedOut else error.RequestFailed;
}

test "HTTPS parser and declared-origin matcher use the exact host" {
    const parsed = try parseHttpsUrl("https://api.example.com:8443/v1?a=1");
    try std.testing.expectEqualStrings("api.example.com:8443", parsed.declared_host);
    try std.testing.expectEqualStrings("api.example.com", parsed.connection_host);
    try std.testing.expectEqualStrings("/v1?a=1", parsed.path);
    try std.testing.expectEqual(@as(u16, 8443), parsed.port);
    try std.testing.expect(originDeclared(&.{"API.EXAMPLE.COM:8443"}, parsed.declared_host));
    try std.testing.expect(!originDeclared(&.{"example.com"}, parsed.declared_host));
    const ipv6 = try parseHttpsUrl("https://[::1]:9443/status");
    try std.testing.expectEqualStrings("[::1]:9443", ipv6.declared_host);
    try std.testing.expectEqualStrings("::1", ipv6.connection_host);
    try std.testing.expectError(error.HttpsRequired, parseHttpsUrl("http://api.example.com"));
}
