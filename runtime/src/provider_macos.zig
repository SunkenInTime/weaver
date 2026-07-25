const std = @import("std");
const protocol = @import("provider_protocol.zig");

const reader_stack_bytes: usize = 256 * 1024;

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

    pub fn init(self: *Client, io: std.Io, endpoint: ?[]const u8) !void {
        const path = endpoint orelse return;
        const address = try std.Io.net.UnixAddress.init(path);
        self.io = io;
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
        var write_buffer: [protocol.command_line_capacity + 1]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        writer.interface.writeAll(framed[0 .. line.len + 1]) catch {
            self.connected.store(0, .release);
            self.disconnected.store(1, .release);
            return error.HostEndpointWriteFailed;
        };
        writer.interface.flush() catch return error.HostEndpointWriteFailed;
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
        }
        const stream = self.stream orelse return;
        var buffer: [protocol.frame_line_capacity * 2]u8 = undefined;
        var reader = stream.reader(self.io, &buffer);
        while (reader.interface.takeDelimiter('\n') catch {
            self.queues.ack_protocol_failed.store(1, .release);
            return;
        }) |line| self.queues.routeLine(line);
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
