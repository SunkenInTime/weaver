const std = @import("std");
const media_protocol = @import("media_protocol.zig");

pub const frame_line_capacity: usize = media_protocol.max_media_frame_bytes;
pub const frame_queue_capacity: usize = 4;
pub const ack_queue_capacity: usize = 4;
pub const command_line_capacity: usize = 256;
pub const max_safe_id: u64 = 9_007_199_254_740_991;

pub const Ack = struct {
    id: u64,
    ok: bool,
};

const AckWire = struct {
    ack: u64,
    ok: bool,
};

const FrameEntry = struct {
    bytes: [frame_line_capacity]u8 = undefined,
    len: usize = 0,
};

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

/// The platform reader thread calls `routeLine`; the app loop calls `take*`.
/// Provider frames retain their established drop-oldest semantics. Acks have
/// their own structurally non-lossy lane sized to the four-pending command cap.
pub const Queues = struct {
    mutex: SpinMutex = .{},
    frames: [frame_queue_capacity]FrameEntry = [_]FrameEntry{.{}} ** frame_queue_capacity,
    frame_head: usize = 0,
    frame_count: usize = 0,
    acks: [ack_queue_capacity]Ack = undefined,
    ack_head: usize = 0,
    ack_count: usize = 0,
    ack_protocol_failed: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub fn routeLine(self: *Queues, line: []const u8) void {
        const envelope = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, line, .{}) catch {
            if (std.mem.indexOf(u8, line, "\"ack\"") != null) self.ack_protocol_failed.store(1, .release);
            return self.pushFrame(line);
        };
        defer envelope.deinit();
        const is_ack = switch (envelope.value) {
            .object => |object| object.contains("ack"),
            else => false,
        };
        if (is_ack) {
            const parsed = std.json.parseFromSlice(AckWire, std.heap.page_allocator, line, .{
                .ignore_unknown_fields = false,
            }) catch {
                self.ack_protocol_failed.store(1, .release);
                return;
            };
            defer parsed.deinit();
            if (parsed.value.ack == 0 or parsed.value.ack > max_safe_id) {
                self.ack_protocol_failed.store(1, .release);
                return;
            }
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.ack_count == self.acks.len) {
                self.ack_protocol_failed.store(1, .release);
                return;
            }
            const index = (self.ack_head + self.ack_count) % self.acks.len;
            self.acks[index] = .{ .id = parsed.value.ack, .ok = parsed.value.ok };
            self.ack_count += 1;
            return;
        }
        self.pushFrame(line);
    }

    fn pushFrame(self: *Queues, line: []const u8) void {
        if (line.len == 0 or line.len > frame_line_capacity) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.frame_count == self.frames.len) {
            self.frame_head = (self.frame_head + 1) % self.frames.len;
            self.frame_count -= 1;
        }
        const index = (self.frame_head + self.frame_count) % self.frames.len;
        @memcpy(self.frames[index].bytes[0..line.len], line);
        self.frames[index].len = line.len;
        self.frame_count += 1;
    }

    pub fn takeFrame(self: *Queues, output: []u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.frame_count == 0) return null;
        const entry = &self.frames[self.frame_head];
        if (entry.len > output.len) return null;
        @memcpy(output[0..entry.len], entry.bytes[0..entry.len]);
        self.frame_head = (self.frame_head + 1) % self.frames.len;
        self.frame_count -= 1;
        return output[0..entry.len];
    }

    pub fn takeAck(self: *Queues) ?Ack {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.ack_count == 0) return null;
        const result = self.acks[self.ack_head];
        self.ack_head = (self.ack_head + 1) % self.acks.len;
        self.ack_count -= 1;
        return result;
    }
};

test "interleaved frames coalesce while four acks never drop" {
    var queues: Queues = .{};
    queues.routeLine("{\"provider\":\"cpu\",\"value\":{\"percent\":1}}");
    queues.routeLine("{\"ack\":1,\"ok\":true}");
    queues.routeLine("{\"provider\":\"cpu\",\"value\":{\"percent\":2}}");
    queues.routeLine("{\"ack\":2,\"ok\":false}");
    queues.routeLine("{\"provider\":\"cpu\",\"value\":{\"percent\":3}}");
    queues.routeLine("{\"provider\":\"cpu\",\"value\":{\"percent\":4}}");
    queues.routeLine("{\"provider\":\"cpu\",\"value\":{\"percent\":5}}");
    queues.routeLine("{\"ack\":3,\"ok\":true}");
    queues.routeLine("{\"ack\":4,\"ok\":true}");

    var output: [frame_line_capacity]u8 = undefined;
    try std.testing.expectEqualStrings("{\"provider\":\"cpu\",\"value\":{\"percent\":2}}", queues.takeFrame(&output).?);
    try std.testing.expectEqualStrings("{\"provider\":\"cpu\",\"value\":{\"percent\":3}}", queues.takeFrame(&output).?);
    try std.testing.expectEqualStrings("{\"provider\":\"cpu\",\"value\":{\"percent\":4}}", queues.takeFrame(&output).?);
    try std.testing.expectEqualStrings("{\"provider\":\"cpu\",\"value\":{\"percent\":5}}", queues.takeFrame(&output).?);
    for ([_]Ack{
        .{ .id = 1, .ok = true },
        .{ .id = 2, .ok = false },
        .{ .id = 3, .ok = true },
        .{ .id = 4, .ok = true },
    }) |expected| try std.testing.expectEqualDeep(expected, queues.takeAck().?);
}

test "partial framing stays outside demux and malformed ack poisons only ack lane" {
    var queues: Queues = .{};
    queues.routeLine("{\"ack\":1}");
    try std.testing.expectEqual(@as(u8, 1), queues.ack_protocol_failed.load(.acquire));
    try std.testing.expect(queues.takeAck() == null);
    var output: [frame_line_capacity]u8 = undefined;
    try std.testing.expect(queues.takeFrame(&output) == null);
}
