const std = @import("std");

pub const max_line_bytes: usize = 256;
pub const queue_capacity: usize = 8;
/// Four live runtime requests plus the complete five-command rate-limit burst
/// can require negative acknowledgements before the host loop next drains.
/// Beyond this proven lane bound the reader applies backpressure; it never
/// accepts another command until the pending nack has a reserved slot.
pub const nack_capacity: usize = 4 + max_verbs_per_second;
pub const max_safe_id: u64 = 9_007_199_254_740_991;
pub const max_verbs_per_second: usize = 5;

pub const Verb = enum { play, pause, next, previous, seek };

pub const Command = struct {
    id: u64,
    verb: Verb,
    seek_ms: ?u64 = null,
};

const WireCommand = struct {
    command: []const u8,
    verb: []const u8,
    seekMs: ?u64 = null,
    id: u64,
};

pub fn parse(line: []const u8) !Command {
    if (line.len == 0 or line.len > max_line_bytes) return error.InvalidCommandFrame;
    const parsed = try std.json.parseFromSlice(WireCommand, std.heap.page_allocator, line, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.command, "media")) return error.InvalidCommand;
    if (parsed.value.id == 0 or parsed.value.id > max_safe_id) return error.InvalidCommandId;
    const verb: Verb = if (std.mem.eql(u8, parsed.value.verb, "play"))
        .play
    else if (std.mem.eql(u8, parsed.value.verb, "pause"))
        .pause
    else if (std.mem.eql(u8, parsed.value.verb, "next"))
        .next
    else if (std.mem.eql(u8, parsed.value.verb, "previous"))
        .previous
    else if (std.mem.eql(u8, parsed.value.verb, "seek"))
        .seek
    else
        return error.InvalidCommandVerb;
    if ((verb == .seek) != (parsed.value.seekMs != null)) return error.InvalidSeek;
    return .{ .id = parsed.value.id, .verb = verb, .seek_ms = parsed.value.seekMs };
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

/// Reader threads are the only producers and the supervision loop is the only
/// consumer. Overflowed, otherwise-valid commands retain their ID in a
/// separate bounded nack lane so the host loop remains the sole pipe writer.
pub const Queue = struct {
    mutex: SpinMutex = .{},
    commands: [queue_capacity]Command = undefined,
    command_head: usize = 0,
    command_count: usize = 0,
    nacks: [nack_capacity]u64 = undefined,
    nack_head: usize = 0,
    nack_count: usize = 0,
    malformed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn pushLine(self: *Queue, line: []const u8) void {
        const command = parse(line) catch {
            self.malformed.store(true, .release);
            return;
        };
        var spins: usize = 0;
        while (true) {
            self.mutex.lock();
            if (self.stopping.load(.acquire)) {
                self.mutex.unlock();
                return;
            }
            if (self.command_count < self.commands.len) {
                const index = (self.command_head + self.command_count) % self.commands.len;
                self.commands[index] = command;
                self.command_count += 1;
                self.mutex.unlock();
                return;
            }
            if (self.nack_count < self.nacks.len) {
                const index = (self.nack_head + self.nack_count) % self.nacks.len;
                self.nacks[index] = command.id;
                self.nack_count += 1;
                self.mutex.unlock();
                return;
            }
            self.mutex.unlock();
            spins += 1;
            if (spins % 1024 == 0) std.Thread.yield() catch {};
            std.atomic.spinLoopHint();
        }
    }

    pub fn take(self: *Queue) ?Command {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.command_count == 0) return null;
        const result = self.commands[self.command_head];
        self.command_head = (self.command_head + 1) % self.commands.len;
        self.command_count -= 1;
        return result;
    }

    pub fn takeNack(self: *Queue) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.nack_count == 0) return null;
        const result = self.nacks[self.nack_head];
        self.nack_head = (self.nack_head + 1) % self.nacks.len;
        self.nack_count -= 1;
        return result;
    }

    pub fn stop(self: *Queue) void {
        self.stopping.store(true, .release);
    }
};

/// Incremental newline framing shared by blocking command readers. A partial
/// final line is malformed; complete lines are parsed before entering Queue.
pub const Framer = struct {
    pending: [max_line_bytes * 2]u8 = undefined,
    pending_len: usize = 0,

    pub fn feed(self: *Framer, queue: *Queue, bytes: []const u8) bool {
        if (bytes.len > self.pending.len - self.pending_len) {
            queue.malformed.store(true, .release);
            return false;
        }
        @memcpy(self.pending[self.pending_len..][0..bytes.len], bytes);
        self.pending_len += bytes.len;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.pending[0..self.pending_len], start, '\n')) |end| {
            queue.pushLine(self.pending[start..end]);
            start = end + 1;
        }
        if (start > 0) {
            std.mem.copyForwards(u8, self.pending[0 .. self.pending_len - start], self.pending[start..self.pending_len]);
            self.pending_len -= start;
        }
        return true;
    }

    pub fn finish(self: *Framer, queue: *Queue) void {
        if (self.pending_len != 0) queue.malformed.store(true, .release);
        self.pending_len = 0;
    }
};

/// A fixed sliding window implements "at most 5 accepted verbs in the prior
/// second" without a timer or heap allocation.
pub const RateLimiter = struct {
    accepted_ms: [max_verbs_per_second]u64 = @splat(0),
    count: usize = 0,
    cursor: usize = 0,

    pub fn allow(self: *RateLimiter, now_ms: u64) bool {
        var retained: [max_verbs_per_second]u64 = undefined;
        var retained_count: usize = 0;
        for (0..self.count) |offset| {
            const index = (self.cursor + self.accepted_ms.len - self.count + offset) % self.accepted_ms.len;
            const timestamp = self.accepted_ms[index];
            if (now_ms -| timestamp < 1000) {
                retained[retained_count] = timestamp;
                retained_count += 1;
            }
        }
        self.accepted_ms = @splat(0);
        @memcpy(self.accepted_ms[0..retained_count], retained[0..retained_count]);
        self.count = retained_count;
        self.cursor = retained_count % self.accepted_ms.len;
        if (self.count == self.accepted_ms.len) return false;
        self.accepted_ms[self.cursor] = now_ms;
        self.cursor = (self.cursor + 1) % self.accepted_ms.len;
        self.count += 1;
        return true;
    }
};

pub fn authorize(declared: bool, limiter: *RateLimiter, now_ms: u64) bool {
    return declared and limiter.allow(now_ms);
}

pub fn formatAck(id: u64, ok: bool, output: []u8) ![]const u8 {
    return std.fmt.bufPrint(output, "{{\"ack\":{d},\"ok\":{s}}}\n", .{ id, if (ok) "true" else "false" });
}

test "media commands freeze wire keys verbs seek and safe ids" {
    try std.testing.expectEqualDeep(
        Command{ .id = 7, .verb = .play },
        try parse("{\"command\":\"media\",\"verb\":\"play\",\"id\":7}"),
    );
    try std.testing.expectEqualDeep(
        Command{ .id = 8, .verb = .seek, .seek_ms = 1234 },
        try parse("{\"command\":\"media\",\"verb\":\"seek\",\"seekMs\":1234,\"id\":8}"),
    );
    try std.testing.expectError(error.InvalidSeek, parse("{\"command\":\"media\",\"verb\":\"seek\",\"id\":8}"));
    try std.testing.expectError(error.InvalidSeek, parse("{\"command\":\"media\",\"verb\":\"pause\",\"seekMs\":1,\"id\":8}"));
    try std.testing.expectError(error.InvalidCommandId, parse("{\"command\":\"media\",\"verb\":\"play\",\"id\":9007199254740992}"));
}

test "command queue keeps FIFO and overflow IDs enter the nack lane" {
    var queue: Queue = .{};
    var line_buffer: [max_line_bytes]u8 = undefined;
    for (1..queue_capacity + 2) |id| {
        const line = try std.fmt.bufPrint(&line_buffer, "{{\"command\":\"media\",\"verb\":\"play\",\"id\":{d}}}", .{id});
        queue.pushLine(line);
    }
    for (1..queue_capacity + 1) |id| try std.testing.expectEqual(id, queue.take().?.id);
    try std.testing.expect(queue.take() == null);
    try std.testing.expectEqual(@as(u64, queue_capacity + 1), queue.takeNack().?);
}

test "host command queue accounts for every hostile burst command" {
    const Producer = struct {
        queue: *Queue,
        done: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            var line_buffer: [max_line_bytes]u8 = undefined;
            for (1..65) |id| {
                const line = std.fmt.bufPrint(
                    &line_buffer,
                    "{{\"command\":\"media\",\"verb\":\"play\",\"id\":{d}}}",
                    .{id},
                ) catch unreachable;
                self.queue.pushLine(line);
            }
            self.done.store(true, .release);
        }
    };
    var queue: Queue = .{};
    var done = std.atomic.Value(bool).init(false);
    const producer = try std.Thread.spawn(.{}, Producer.run, .{Producer{ .queue = &queue, .done = &done }});
    var accounted: usize = 0;
    while (!done.load(.acquire) or accounted < 64) {
        while (queue.take()) |_| accounted += 1;
        while (queue.takeNack()) |_| accounted += 1;
        if (accounted == 64 and done.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    producer.join();
    try std.testing.expectEqual(@as(usize, 64), accounted);
    try std.testing.expect(!queue.malformed.load(.acquire));
}

test "host command framing preserves partial and adjacent lines" {
    var queue: Queue = .{};
    var framer: Framer = .{};
    try std.testing.expect(framer.feed(&queue, "{\"command\":\"media\",\"verb\":\"pl"));
    try std.testing.expect(queue.take() == null);
    try std.testing.expect(framer.feed(
        &queue,
        "ay\",\"id\":1}\n{\"command\":\"media\",\"verb\":\"pause\",\"id\":2}\n",
    ));
    try std.testing.expectEqual(@as(u64, 1), queue.take().?.id);
    try std.testing.expectEqual(@as(u64, 2), queue.take().?.id);
    try std.testing.expect(framer.feed(&queue, "{\"command\":\"media\""));
    framer.finish(&queue);
    try std.testing.expect(queue.malformed.load(.acquire));
}

test "rate limiter permits five verbs in a sliding second" {
    var limiter: RateLimiter = .{};
    for (0..max_verbs_per_second) |offset| try std.testing.expect(limiter.allow(100 + offset));
    try std.testing.expect(!limiter.allow(999));
    try std.testing.expect(limiter.allow(1100));
}

test "undeclared widgets are refused without consuming rate capacity" {
    var limiter: RateLimiter = .{};
    try std.testing.expect(!authorize(false, &limiter, 100));
    for (0..max_verbs_per_second) |offset| try std.testing.expect(authorize(true, &limiter, 100 + offset));
}

test "ack wire is exact" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{\"ack\":42,\"ok\":false}\n", try formatAck(42, false, &buffer));
}
