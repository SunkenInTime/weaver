const std = @import("std");

const line_capacity: usize = 8192;
const queue_capacity: usize = 4;
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

const Entry = struct {
    bytes: [line_capacity]u8 = undefined,
    len: usize = 0,
};

/// The Unix-socket reader owns no QuickJS state. It only copies complete JSON
/// lines into the same bounded queue as the Windows pipe client; the app-loop
/// timer remains the sole place provider callbacks enter JavaScript.
pub const Client = struct {
    io: std.Io = undefined,
    stream: ?std.Io.net.Stream = null,
    thread: ?std.Thread = null,
    mutex: SpinMutex = .{},
    queue: [queue_capacity]Entry = [_]Entry{.{}} ** queue_capacity,
    head: usize = 0,
    count: usize = 0,
    available: bool = false,

    pub fn init(self: *Client, io: std.Io, endpoint: ?[]const u8) !void {
        const path = endpoint orelse return;
        const address = try std.Io.net.UnixAddress.init(path);
        self.io = io;
        self.stream = address.connect(io) catch return error.HostEndpointUnavailable;
        errdefer {
            self.stream.?.close(io);
            self.stream = null;
        }
        self.available = true;
        self.thread = try std.Thread.spawn(.{ .stack_size = reader_stack_bytes }, readerMain, .{self});
    }

    pub fn deinit(self: *Client) void {
        if (self.stream) |stream| stream.close(self.io);
        self.stream = null;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.available = false;
    }

    pub fn take(self: *Client, output: []u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count == 0) return null;
        const entry = &self.queue[self.head];
        if (entry.len > output.len) return null;
        @memcpy(output[0..entry.len], entry.bytes[0..entry.len]);
        self.head = (self.head + 1) % self.queue.len;
        self.count -= 1;
        return output[0..entry.len];
    }

    fn push(self: *Client, line: []const u8) void {
        if (line.len == 0 or line.len > line_capacity) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count == self.queue.len) {
            self.head = (self.head + 1) % self.queue.len;
            self.count -= 1;
        }
        const index = (self.head + self.count) % self.queue.len;
        @memcpy(self.queue[index].bytes[0..line.len], line);
        self.queue[index].len = line.len;
        self.count += 1;
    }

    fn readerMain(self: *Client) void {
        const stream = self.stream orelse return;
        var buffer: [line_capacity * 2]u8 = undefined;
        var reader = stream.reader(self.io, &buffer);
        while (reader.interface.takeDelimiter('\n') catch return) |line| self.push(line);
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
        client.mutex.lock();
        ready = client.count == queue_capacity;
        client.mutex.unlock();
        if (ready) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(ready);
    var output: [line_capacity]u8 = undefined;
    for ([_][]const u8{ "two", "three", "four", "five" }) |expected| {
        try std.testing.expectEqualStrings(expected, client.take(&output).?);
    }
    try std.testing.expect(client.take(&output) == null);
}
