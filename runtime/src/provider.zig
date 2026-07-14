const std = @import("std");
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

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

/// The pipe reader owns no QuickJS state. It only copies complete JSON lines
/// into a four-entry queue; the Native timer drain remains the sole place
/// where provider callbacks enter JavaScript on the app loop thread.
pub const Client = struct {
    handle: win.HANDLE = win.INVALID_HANDLE_VALUE,
    thread: ?std.Thread = null,
    mutex: SpinMutex = .{},
    queue: [queue_capacity]Entry = [_]Entry{.{}} ** queue_capacity,
    head: usize = 0,
    count: usize = 0,
    available: bool = false,

    pub fn init(self: *Client, pipe_name: ?[]const u8) !void {
        const name = pipe_name orelse return;
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, name);
        defer std.heap.page_allocator.free(name_w);
        self.handle = win.CreateFileW(name_w.ptr, win.GENERIC_READ, 0, null, win.OPEN_EXISTING, 0, null);
        if (self.handle == win.INVALID_HANDLE_VALUE) return error.HostPipeUnavailable;
        errdefer {
            _ = win.CloseHandle(self.handle);
            self.handle = win.INVALID_HANDLE_VALUE;
        }
        self.available = true;
        // Zig's Windows default reserves 16 MiB per thread. This worker has a
        // 16 KiB accumulator and a shallow call graph, so an explicit bound
        // prevents one optional provider pipe from doubling widget private
        // usage while retaining ample headroom over measured stack use.
        self.thread = try std.Thread.spawn(.{ .stack_size = reader_stack_bytes }, readerMain, .{self});
    }

    pub fn deinit(self: *Client) void {
        if (self.handle != win.INVALID_HANDLE_VALUE) {
            _ = win.CancelIoEx(self.handle, null);
            _ = win.CloseHandle(self.handle);
            self.handle = win.INVALID_HANDLE_VALUE;
        }
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
        var pending: [line_capacity * 2]u8 = undefined;
        var pending_len: usize = 0;
        while (true) {
            var read: win.DWORD = 0;
            if (pending_len == pending.len) pending_len = 0;
            if (win.ReadFile(self.handle, pending[pending_len..].ptr, @intCast(pending.len - pending_len), &read, null) == 0 or read == 0) return;
            pending_len += read;
            var start: usize = 0;
            while (std.mem.indexOfScalarPos(u8, pending[0..pending_len], start, '\n')) |end| {
                self.push(pending[start..end]);
                start = end + 1;
            }
            if (start > 0) {
                std.mem.copyForwards(u8, pending[0 .. pending_len - start], pending[start..pending_len]);
                pending_len -= start;
            }
        }
    }
};

test "provider client is inert without a host pipe" {
    var client: Client = .{};
    try client.init(null);
    defer client.deinit();
    try std.testing.expect(!client.available);
}
