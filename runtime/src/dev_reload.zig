const std = @import("std");

pub const signal_file_name = ".weaver-dev-port";

/// Event-driven dev hot reload. The listener blocks in the kernel while the
/// source tree is idle; one loopback connection from the CLI produces exactly
/// one callback and no timer is armed in the widget process.
pub const Server = struct {
    io: ?std.Io = null,
    listener: ?std.Io.net.Server = null,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    signal_path: []const u8 = &.{},
    notify: ?*const fn () void = null,
    port: u16 = 0,

    pub fn start(self: *Server, io: std.Io, signal_path: []const u8, notify: *const fn () void) !void {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.io = io;
        self.signal_path = signal_path;
        self.notify = notify;
        self.listener = try std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true });
        errdefer {
            self.listener.?.deinit(io);
            self.listener = null;
        }
        self.port = self.listener.?.socket.address.getPort();
        var port_buffer: [8]u8 = undefined;
        const port_text = try std.fmt.bufPrint(&port_buffer, "{d}\n", .{self.port});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = signal_path, .data = port_text });
        errdefer std.Io.Dir.cwd().deleteFile(io, signal_path) catch {};
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *Server) void {
        const io = self.io orelse return;
        self.stopping.store(true, .release);
        // Wake the blocking accept with an ordinary connection. Closing a
        // Windows listener underneath std.Io's accept reports CANCELLED as an
        // internal invariant violation; the loopback wake is portable and
        // lets the server thread return before the socket is destroyed.
        if (self.port != 0) {
            const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch unreachable;
            if (std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp })) |stream| {
                stream.close(io);
            } else |_| {}
        }
        if (self.thread) |thread| thread.join();
        if (self.listener) |*listener| listener.deinit(io);
        if (self.signal_path.len != 0) std.Io.Dir.cwd().deleteFile(io, self.signal_path) catch {};
        self.thread = null;
        self.listener = null;
        self.io = null;
        self.notify = null;
        self.port = 0;
    }

    fn run(self: *Server) void {
        const io = self.io orelse return;
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.?.accept(io) catch return;
            stream.close(io);
            if (self.stopping.load(.acquire)) return;
            (self.notify orelse return)();
        }
    }
};

var test_notifications = std.atomic.Value(u32).init(0);

fn noteTestNotification() void {
    _ = test_notifications.fetchAdd(1, .acq_rel);
}

test "loopback connection emits one reload without a polling timer" {
    const signal_path = "weaver-dev-reload-test.port";
    std.Io.Dir.cwd().deleteFile(std.testing.io, signal_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, signal_path) catch {};
    test_notifications.store(0, .release);

    var server: Server = .{};
    try server.start(std.testing.io, signal_path, noteTestNotification);
    defer server.deinit();

    const port_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, signal_path, std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(port_text);
    try std.testing.expectEqual(server.port, try std.fmt.parseInt(u16, std.mem.trim(u8, port_text, " \r\n\t"), 10));

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", server.port);
    const stream = try std.Io.net.IpAddress.connect(&address, std.testing.io, .{ .mode = .stream, .protocol = .tcp });
    stream.close(std.testing.io);
    for (0..100) |_| {
        if (test_notifications.load(.acquire) == 1) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expectEqual(@as(u32, 1), test_notifications.load(.acquire));
}
