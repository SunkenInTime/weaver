const std = @import("std");
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});
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

/// The pipe reader owns no QuickJS state. It only copies complete JSON lines
/// into the provider/ack queues; the Native timer drain remains the sole place
/// where callbacks enter JavaScript on the app loop thread.
pub const Client = struct {
    io: std.Io = undefined,
    handle: win.HANDLE = win.INVALID_HANDLE_VALUE,
    thread: ?std.Thread = null,
    send_mutex: SpinMutex = .{},
    queues: protocol.Queues = .{},
    connected: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    disconnected: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    next_command_id: u64 = 1,

    pub fn init(self: *Client, io: std.Io, pipe_name: ?[]const u8) !void {
        self.io = io;
        const name = pipe_name orelse return;
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, name);
        defer std.heap.page_allocator.free(name_w);
        self.handle = win.CreateFileW(name_w.ptr, win.GENERIC_READ | win.GENERIC_WRITE, 0, null, win.OPEN_EXISTING, 0, null);
        if (self.handle == win.INVALID_HANDLE_VALUE) return error.HostPipeUnavailable;
        errdefer {
            _ = win.CloseHandle(self.handle);
            self.handle = win.INVALID_HANDLE_VALUE;
        }
        self.connected.store(1, .release);
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
        if (!self.isAvailable() or self.handle == win.INVALID_HANDLE_VALUE) return error.HostPipeUnavailable;
        var framed: [protocol.command_line_capacity + 1]u8 = undefined;
        @memcpy(framed[0..line.len], line);
        framed[line.len] = '\n';
        var written: win.DWORD = 0;
        if (win.WriteFile(self.handle, &framed, @intCast(line.len + 1), &written, null) == 0 or written != line.len + 1) {
            self.connected.store(0, .release);
            self.disconnected.store(1, .release);
            return error.HostPipeWriteFailed;
        }
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
        var pending: [protocol.frame_line_capacity * 2]u8 = undefined;
        var pending_len: usize = 0;
        while (true) {
            var read: win.DWORD = 0;
            if (pending_len == pending.len) {
                self.queues.ack_protocol_failed.store(1, .release);
                return;
            }
            if (win.ReadFile(self.handle, pending[pending_len..].ptr, @intCast(pending.len - pending_len), &read, null) == 0 or read == 0) {
                if (pending_len != 0) self.queues.ack_protocol_failed.store(1, .release);
                return;
            }
            pending_len += read;
            var start: usize = 0;
            while (std.mem.indexOfScalarPos(u8, pending[0..pending_len], start, '\n')) |end| {
                self.queues.routeLine(pending[start..end]);
                start = end + 1;
            }
            if (start > 0) {
                std.mem.copyForwards(u8, pending[0 .. pending_len - start], pending[start..pending_len]);
                pending_len -= start;
            }
        }
    }
};
