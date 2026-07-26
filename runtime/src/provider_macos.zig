const std = @import("std");
const c = @cImport({
    @cInclude("sys/socket.h");
});
const posix = std.posix;
const protocol = @import("provider_protocol.zig");

const reader_stack_bytes: usize = 256 * 1024;
const command_write_deadline_ns: i128 = std.time.ns_per_s;

const SendAttempt = union(enum) {
    progress: usize,
    retry,
    failure,
};

const SendFn = *const fn (?*anyopaque, c_int, []const u8) SendAttempt;

fn systemSend(_: ?*anyopaque, socket: c_int, bytes: []const u8) SendAttempt {
    const sent = c.send(
        socket,
        bytes.ptr,
        bytes.len,
        c.MSG_DONTWAIT | c.MSG_NOSIGNAL,
    );
    if (sent > 0) return .{ .progress = @intCast(sent) };
    return switch (posix.errno(sent)) {
        .INTR, .AGAIN => .retry,
        else => .failure,
    };
}

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

/// The Unix-socket reader owns no QuickJS state. It only copies complete JSON
/// lines into separate provider/ack queues; the app-loop timer remains the
/// sole place callbacks enter JavaScript.
pub const Client = struct {
    io: std.Io = undefined,
    stream: ?std.Io.net.Stream = null,
    thread: ?std.Thread = null,
    send_mutex: SpinMutex = .{},
    queues: protocol.Queues = .{},
    connected: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    disconnected: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    next_command_id: u64 = 1,
    wake: ?*const fn () void = null,
    send_fn: SendFn = systemSend,
    send_context: ?*anyopaque = null,
    send_deadline_ns: i128 = command_write_deadline_ns,

    pub fn init(self: *Client, io: std.Io, endpoint: ?[]const u8) !void {
        // Inert clients still provide the monotonic clock used by transport
        // deadline bookkeeping; endpoint absence must not leave `io`
        // undefined.
        self.io = io;
        const path = endpoint orelse return;
        const address = try std.Io.net.UnixAddress.init(path);
        self.stream = address.connect(io) catch return error.HostEndpointUnavailable;
        errdefer {
            self.stream.?.close(io);
            self.stream = null;
        }
        self.connected.store(1, .release);
        self.thread = try std.Thread.spawn(.{ .stack_size = reader_stack_bytes }, readerMain, .{self});
    }

    pub fn deinit(self: *Client) void {
        if (self.stream) |stream| stream.close(self.io);
        self.stream = null;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.connected.store(0, .release);
        self.disconnected.store(1, .release);
    }

    pub fn take(self: *Client, output: []u8) ?[]const u8 {
        return self.queues.takeFrame(output);
    }

    pub fn takeAck(self: *Client) ?protocol.Ack {
        return self.queues.takeAck();
    }

    pub fn registerAck(self: *Client, id: u64) bool {
        return self.queues.registerAck(id);
    }

    pub fn unregisterAck(self: *Client, id: u64) void {
        self.queues.unregisterAck(id);
    }

    pub fn setWake(self: *Client, wake: *const fn () void) void {
        self.wake = wake;
    }

    pub fn isAvailable(self: *const Client) bool {
        return self.connected.load(.acquire) != 0;
    }

    pub fn protocolFailed(self: *const Client) bool {
        return self.queues.ack_protocol_failed.load(.acquire) != 0;
    }

    pub fn isDisconnected(self: *const Client) bool {
        return self.disconnected.load(.acquire) != 0;
    }

    pub fn nowMilliseconds(self: *const Client) u64 {
        return @intCast(std.Io.Clock.now(.awake, self.io).toMilliseconds());
    }

    pub fn send(self: *Client, line: []const u8) !void {
        if (line.len == 0 or line.len > protocol.command_line_capacity or std.mem.indexOfScalar(u8, line, '\n') != null) return error.InvalidCommandFrame;
        self.send_mutex.lock();
        defer self.send_mutex.unlock();
        const stream = self.stream orelse return error.HostEndpointUnavailable;
        if (!self.isAvailable()) return error.HostEndpointUnavailable;
        var framed: [protocol.command_line_capacity + 1]u8 = undefined;
        @memcpy(framed[0..line.len], line);
        framed[line.len] = '\n';
        const started_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        var offset: usize = 0;
        while (offset < line.len + 1) {
            switch (self.send_fn(self.send_context, stream.socket.handle, framed[offset .. line.len + 1])) {
                .progress => |sent| {
                    offset += sent;
                    continue;
                },
                .retry => {},
                .failure => return self.failWrite(),
            }
            if (std.Io.Timestamp.now(self.io, .awake).nanoseconds - started_ns >= self.send_deadline_ns) {
                return self.failWrite();
            }
            std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch return self.failWrite();
        }
    }

    fn failWrite(self: *Client) error{HostEndpointWriteFailed} {
        self.connected.store(0, .release);
        self.disconnected.store(1, .release);
        return error.HostEndpointWriteFailed;
    }

    pub fn nextCommandId(self: *Client) !u64 {
        if (self.next_command_id > protocol.max_safe_id) return error.CommandIdExhausted;
        const result = self.next_command_id;
        self.next_command_id += 1;
        return result;
    }

    fn readerMain(self: *Client) void {
        defer {
            self.connected.store(0, .release);
            self.disconnected.store(1, .release);
            if (self.wake) |wake| wake();
        }
        const stream = self.stream orelse return;
        var reader_buffer: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &reader_buffer);
        var framer: protocol.Framer = .{};
        var chunk: [4096]u8 = undefined;
        while (true) {
            const read = reader.interface.readSliceShort(&chunk) catch {
                framer.finish(&self.queues);
                return;
            };
            if (read == 0) {
                framer.finish(&self.queues);
                return;
            }
            const wake_before = self.queues.wakeGeneration();
            if (!framer.feed(&self.queues, chunk[0..read])) return;
            if (self.queues.wakeGeneration() != wake_before) {
                if (self.wake) |wake| wake();
            }
        }
    }
};

const TestEndpoint = struct {
    io: std.Io,
    listener: std.Io.net.Server,

    fn run(self: *TestEndpoint) void {
        const stream = self.listener.accept(self.io) catch return;
        defer stream.close(self.io);
        var buffer: [256]u8 = undefined;
        var writer = stream.writer(self.io, &buffer);
        writer.interface.writeAll("one\ntwo\nthree\nfour\nfive\n") catch return;
        writer.interface.flush() catch {};
    }
};

test "inert Unix provider client retains a valid monotonic clock" {
    var client: Client = .{};
    try client.init(std.testing.io, null);
    defer client.deinit();
    try std.testing.expect(client.nowMilliseconds() > 0);
    try std.testing.expect(!client.isAvailable());
}

test "Unix provider transport frames lines and bounds its queue" {
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/weaver-provider-test-{d}.sock", .{std.posix.system.getpid()});
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const address = try std.Io.net.UnixAddress.init(path);
    var endpoint: TestEndpoint = .{ .io = std.testing.io, .listener = try address.listen(std.testing.io, .{}) };
    defer endpoint.listener.deinit(std.testing.io);
    const server_thread = try std.Thread.spawn(.{}, TestEndpoint.run, .{&endpoint});
    defer server_thread.join();

    var client: Client = .{};
    try client.init(std.testing.io, path);
    defer client.deinit();
    var ready = false;
    for (0..100) |_| {
        client.queues.mutex.lock();
        ready = client.queues.frame_count == protocol.frame_queue_capacity;
        client.queues.mutex.unlock();
        if (ready) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(ready);
    var output: [protocol.frame_line_capacity]u8 = undefined;
    for ([_][]const u8{ "two", "three", "four", "five" }) |expected| {
        try std.testing.expectEqualStrings(expected, client.take(&output).?);
    }
    try std.testing.expect(client.take(&output) == null);
}

test "Unix provider transport rejects an unterminated ack at EOF" {
    const Endpoint = struct {
        io: std.Io,
        listener: std.Io.net.Server,

        fn run(self: *@This()) void {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            var buffer: [64]u8 = undefined;
            var writer = stream.writer(self.io, &buffer);
            writer.interface.writeAll("{\"ack\":7,\"ok\":true}") catch return;
            writer.interface.flush() catch {};
        }
    };
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/weaver-provider-eof-test-{d}.sock", .{std.posix.system.getpid()});
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const address = try std.Io.net.UnixAddress.init(path);
    var endpoint: Endpoint = .{ .io = std.testing.io, .listener = try address.listen(std.testing.io, .{}) };
    defer endpoint.listener.deinit(std.testing.io);
    const server_thread = try std.Thread.spawn(.{}, Endpoint.run, .{&endpoint});
    defer server_thread.join();
    var client: Client = .{};
    try client.init(std.testing.io, path);
    defer client.deinit();
    try std.testing.expect(client.registerAck(7));
    for (0..100) |_| {
        if (client.isDisconnected()) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(client.protocolFailed());
    try std.testing.expect(client.takeAck() == null);
}

test "Unix provider command send has a deadline when the connected host stalls" {
    const Endpoint = struct {
        io: std.Io,
        listener: std.Io.net.Server,
        stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            while (!self.stopping.load(.acquire)) {
                std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch return;
            }
        }
    };
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/weaver-provider-stall-test-{d}.sock", .{std.posix.system.getpid()});
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const address = try std.Io.net.UnixAddress.init(path);
    var endpoint: Endpoint = .{ .io = std.testing.io, .listener = try address.listen(std.testing.io, .{}) };
    defer endpoint.listener.deinit(std.testing.io);
    const server_thread = try std.Thread.spawn(.{}, Endpoint.run, .{&endpoint});
    defer server_thread.join();

    var client: Client = .{};
    client.io = std.testing.io;
    client.stream = try address.connect(std.testing.io);
    client.connected.store(1, .release);
    defer client.deinit();
    defer endpoint.stopping.store(true, .release);

    const StalledSend = struct {
        attempts: usize = 0,

        fn send(context: ?*anyopaque, _: c_int, _: []const u8) SendAttempt {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.attempts += 1;
            return .retry;
        }
    };
    var stalled_send: StalledSend = .{};
    client.send_fn = StalledSend.send;
    client.send_context = &stalled_send;
    client.send_deadline_ns = 20 * std.time.ns_per_ms;

    const started = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
    try std.testing.expectError(error.HostEndpointWriteFailed, client.send("{\"command\":\"media\",\"verb\":\"pause\",\"id\":1}"));
    const elapsed = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - started;
    try std.testing.expect(elapsed >= client.send_deadline_ns);
    try std.testing.expect(elapsed < 500 * std.time.ns_per_ms);
    try std.testing.expect(stalled_send.attempts > 1);
    try std.testing.expect(client.isDisconnected());
    // The caller is back on the app loop after the finite send deadline, so
    // pending-slot cleanup and promise rejection can run immediately.
    try std.testing.expect(client.nowMilliseconds() > 0);
}
