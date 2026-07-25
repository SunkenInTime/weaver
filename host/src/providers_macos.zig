const std = @import("std");
const art_cache = @import("art_cache.zig");
const media = @import("media.zig");
const media_commands = @import("media_commands.zig");
const protocol = @import("provider_protocol.zig");

const c = @cImport({
    @cInclude("macos_system.h");
});
const posix = std.posix;

pub const media_stream_line_bytes: usize = 2 * 1024 * 1024;
pub const media_restart_initial_ms: u64 = 1000;
pub const media_restart_max_ms: u64 = 30_000;
pub const media_command_timeout_ms: i64 = 2500;

pub const MediaAvailability = enum {
    idle,
    starting,
    live,
    unavailable,

    pub fn label(self: MediaAvailability) []const u8 {
        return switch (self) {
            .idle => "idle",
            .starting => "starting",
            .live => "available",
            .unavailable => "unavailable",
        };
    }
};

const StreamEnvelope = struct {
    type: []const u8,
    diff: bool,
    payload: Payload,
};

const Payload = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    bundleIdentifier: ?[]const u8 = null,
    playing: ?bool = null,
    elapsedTime: ?f64 = null,
    elapsedTimeNow: ?f64 = null,
    duration: ?f64 = null,
    artworkData: ?[]const u8 = null,
};

const QueuedFrame = struct {
    frame: media.Frame,
    force: bool = false,
};

const AdapterCommand = struct {
    action: []const u8,
    argument: [32]u8 = @splat(0),
    argument_len: usize,

    fn argumentSlice(self: *const AdapterCommand) []const u8 {
        return self.argument[0..self.argument_len];
    }
};

/// Owns the exact adapter boundary established by the attended-Mac spike:
/// one long-lived stdout metadata stream and separate bounded command
/// processes. Widget-visible traffic remains on macos_host's per-widget UDS.
pub const MediaProvider = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    script_path: []const u8,
    framework_path: []const u8,
    cache: *art_cache.Cache,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    child_pid: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    mutex: std.Io.Mutex = .init,
    availability: MediaAvailability = .idle,
    pending_frame: ?media.Frame = null,
    loss_pending: bool = false,
    current_duration_ms: u64 = 0,

    pub fn setActive(self: *MediaProvider, active: bool) void {
        if (active) {
            if (self.thread != null) return;
            self.stopping.store(false, .release);
            self.setAvailability(.starting);
            self.thread = std.Thread.spawn(.{ .stack_size = media_stream_line_bytes + 512 * 1024 }, streamMain, .{self}) catch {
                self.recordLoss();
                return;
            };
            return;
        }
        self.stop();
    }

    pub fn deinit(self: *MediaProvider) void {
        self.stop();
    }

    pub fn takeFrame(self: *MediaProvider) ?QueuedFrame {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.loss_pending) {
            self.loss_pending = false;
            return .{ .frame = .{}, .force = true };
        }
        const frame = self.pending_frame orelse return null;
        self.pending_frame = null;
        return .{ .frame = frame };
    }

    pub fn availabilityLabel(self: *MediaProvider) []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.availability.label();
    }

    pub fn command(self: *MediaProvider, command_value: media_commands.Command) bool {
        self.mutex.lockUncancelable(self.io);
        const duration_ms = self.current_duration_ms;
        self.mutex.unlock(self.io);
        const invocation = adapterCommand(command_value, duration_ms) catch return false;
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "/usr/bin/perl", self.script_path, self.framework_path, invocation.action, invocation.argumentSlice() },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(16 * 1024),
            .timeout = .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(media_command_timeout_ms),
            } },
        }) catch return false;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        return switch (result.term) {
            .exited => |code| code == 0 and result.stdout.len == 0,
            else => false,
        };
    }

    fn stop(self: *MediaProvider) void {
        const thread = self.thread orelse {
            self.setAvailability(.idle);
            return;
        };
        self.stopping.store(true, .release);
        const pid = self.child_pid.load(.acquire);
        if (pid > 0) posix.kill(pid, .TERM) catch {};
        thread.join();
        self.thread = null;
        self.child_pid.store(0, .release);
        self.mutex.lockUncancelable(self.io);
        self.pending_frame = null;
        self.loss_pending = false;
        self.availability = .idle;
        self.current_duration_ms = 0;
        self.mutex.unlock(self.io);
    }

    fn streamMain(self: *MediaProvider) void {
        var backoff_ms = media_restart_initial_ms;
        while (!self.stopping.load(.acquire)) {
            var child = std.process.spawn(self.io, .{
                .argv = &.{
                    "/usr/bin/perl",
                    self.script_path,
                    self.framework_path,
                    "stream",
                    "--no-diff",
                    "--debounce=100",
                },
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .ignore,
            }) catch {
                self.recordLoss();
                self.sleepBackoff(backoff_ms);
                backoff_ms = @min(backoff_ms * 2, media_restart_max_ms);
                continue;
            };
            self.child_pid.store(child.id.?, .release);
            var malformed = false;
            var read_buffer: [media_stream_line_bytes]u8 = undefined;
            var reader = child.stdout.?.reader(self.io, &read_buffer);
            while (!self.stopping.load(.acquire)) {
                const line = reader.interface.takeDelimiter('\n') catch {
                    malformed = true;
                    break;
                } orelse break;
                const frame = self.parseFrame(line) catch {
                    malformed = true;
                    break;
                };
                backoff_ms = media_restart_initial_ms;
                self.publishFrame(frame);
            }
            if (malformed and child.id != null) child.kill(self.io);
            if (child.id != null) _ = child.wait(self.io) catch {};
            self.child_pid.store(0, .release);
            if (self.stopping.load(.acquire)) break;
            self.recordLoss();
            self.sleepBackoff(backoff_ms);
            backoff_ms = @min(backoff_ms * 2, media_restart_max_ms);
        }
    }

    fn parseFrame(self: *MediaProvider, line: []const u8) !media.Frame {
        const parsed = try std.json.parseFromSlice(StreamEnvelope, self.allocator, line, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.type, "data") or parsed.value.diff) return error.InvalidAdapterFrame;
        const payload = parsed.value.payload;
        const title = payload.title orelse "";
        if (title.len == 0) {
            self.cache.clearPublished();
            return .{};
        }
        var frame: media.Frame = .{
            .status = if (payload.playing orelse false) .playing else .paused,
            .position_ms = secondsToMilliseconds(payload.elapsedTimeNow orelse payload.elapsedTime orelse 0),
            .duration_ms = secondsToMilliseconds(payload.duration orelse 0),
        };
        media.copyText(&frame.title, &frame.title_len, title);
        media.copyText(&frame.artist, &frame.artist_len, payload.artist orelse "");
        media.copyText(&frame.album, &frame.album_len, payload.album orelse "");
        media.copyText(&frame.source_app, &frame.source_app_len, payload.bundleIdentifier orelse "");
        self.cache.clearPublished();
        if (payload.artworkData) |encoded| {
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch 0;
            if (decoded_len > 0 and decoded_len <= art_cache.max_input_bytes) {
                const decoded = try self.allocator.alloc(u8, decoded_len);
                defer self.allocator.free(decoded);
                std.base64.standard.Decoder.decode(decoded, encoded) catch return frame;
                if (try self.cache.publish(decoded)) |publication| {
                    media.copyText(&frame.art_path, &frame.art_path_len, publication.pathSlice());
                }
            }
        }
        return frame;
    }

    fn publishFrame(self: *MediaProvider, frame: media.Frame) void {
        self.mutex.lockUncancelable(self.io);
        self.pending_frame = frame;
        self.current_duration_ms = frame.duration_ms;
        self.availability = .live;
        self.mutex.unlock(self.io);
    }

    fn recordLoss(self: *MediaProvider) void {
        self.mutex.lockUncancelable(self.io);
        if (self.availability != .unavailable) self.loss_pending = true;
        self.pending_frame = null;
        self.current_duration_ms = 0;
        self.availability = .unavailable;
        self.mutex.unlock(self.io);
    }

    fn setAvailability(self: *MediaProvider, availability: MediaAvailability) void {
        self.mutex.lockUncancelable(self.io);
        self.availability = availability;
        self.mutex.unlock(self.io);
    }

    fn sleepBackoff(self: *MediaProvider, milliseconds: u64) void {
        var remaining = milliseconds;
        while (remaining > 0 and !self.stopping.load(.acquire)) {
            const slice = @min(remaining, 50);
            std.Io.sleep(self.io, .fromMilliseconds(slice), .awake) catch return;
            remaining -= slice;
        }
    }
};

fn secondsToMilliseconds(seconds: f64) u64 {
    if (!std.math.isFinite(seconds) or seconds <= 0) return 0;
    const milliseconds = seconds * 1000.0;
    if (milliseconds >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
    return @intFromFloat(@round(milliseconds));
}

fn adapterCommand(command: media_commands.Command, duration_ms: u64) !AdapterCommand {
    var result: AdapterCommand = .{ .action = "send", .argument_len = 1 };
    switch (command.verb) {
        .play => result.argument[0] = '0',
        .pause => result.argument[0] = '1',
        .next => result.argument[0] = '4',
        .previous => result.argument[0] = '5',
        .seek => {
            const requested_ms = command.seek_ms orelse return error.InvalidSeek;
            const clamped_ms = if (duration_ms > 0) @min(requested_ms, duration_ms) else requested_ms;
            const max_ms: u64 = @intCast(@divFloor(std.math.maxInt(i64), 1000));
            result.action = "seek";
            const formatted = try std.fmt.bufPrint(&result.argument, "{d}", .{@min(clamped_ms, max_ms) * 1000});
            result.argument_len = formatted.len;
        },
    }
    return result;
}

pub const Sampler = struct {
    previous: [protocol.max_cores][c.WEAVER_CPU_STATE_COUNT]u32 = @splat(@splat(0)),
    previous_count: usize = 0,
    initialized: bool = false,
    sample_calls: u64 = 0,

    /// `host_processor_info` is one public, host-owned per-core snapshot.
    /// `usedMb` preserves the SDK's existing meaning: total physical memory
    /// minus free and inactive (reclaimable) pages from `host_statistics64`.
    pub fn sample(self: *Sampler) !?protocol.Sample {
        self.sample_calls += 1;
        var ticks: [protocol.max_cores * c.WEAVER_CPU_STATE_COUNT]u32 = undefined;
        var count: usize = 0;
        var used_bytes: u64 = 0;
        var total_bytes: u64 = 0;
        if (c.weaver_system_sample(&ticks, protocol.max_cores, &count, &used_bytes, &total_bytes) != 0 or
            count == 0 or count > protocol.max_cores or total_bytes == 0) return error.ProcessorSampleFailed;
        const memory = memorySample(used_bytes, total_bytes);
        if (!self.initialized or count != self.previous_count) {
            for (0..count) |index| self.remember(index, &ticks);
            self.previous_count = count;
            self.initialized = true;
            return null;
        }

        var cpu: protocol.Cpu = .{ .core_count = count };
        var aggregate_busy: u64 = 0;
        var aggregate_total: u64 = 0;
        for (0..count) |index| {
            var busy: u64 = 0;
            var total: u64 = 0;
            for (0..c.WEAVER_CPU_STATE_COUNT) |state| {
                const now = ticks[index * c.WEAVER_CPU_STATE_COUNT + state];
                const delta: u64 = now -% self.previous[index][state];
                total += delta;
                if (state != c.WEAVER_CPU_STATE_IDLE) busy += delta;
                self.previous[index][state] = now;
            }
            aggregate_busy += busy;
            aggregate_total += total;
            cpu.per_core[index] = protocol.roundTenth(percent(busy, total));
        }
        cpu.percent = protocol.roundTenth(percent(aggregate_busy, aggregate_total));
        return .{ .cpu = cpu, .memory = memory };
    }

    fn remember(self: *Sampler, index: usize, ticks: *const [protocol.max_cores * c.WEAVER_CPU_STATE_COUNT]u32) void {
        for (0..c.WEAVER_CPU_STATE_COUNT) |state| self.previous[index][state] = ticks[index * c.WEAVER_CPU_STATE_COUNT + state];
    }
};

fn memorySample(used_bytes: u64, total_bytes: u64) protocol.Memory {
    const total_mb = total_bytes / (1024 * 1024);
    const used_mb = used_bytes / (1024 * 1024);
    return .{
        .used_mb = used_mb,
        .total_mb = total_mb,
        .percent = protocol.roundTenth(@as(f64, @floatFromInt(used_bytes)) * 100.0 / @as(f64, @floatFromInt(total_bytes))),
    };
}

fn percent(numerator: u64, denominator: u64) f64 {
    if (denominator == 0) return 0;
    return @as(f64, @floatFromInt(numerator)) * 100.0 / @as(f64, @floatFromInt(denominator));
}

test "live sampler reports bounded public CPU and memory shapes" {
    var sampler: Sampler = .{};
    try std.testing.expect(try sampler.sample() == null);
    try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    const sample = (try sampler.sample()).?;
    try std.testing.expect(sample.cpu.core_count > 0);
    try std.testing.expect(sample.cpu.percent >= 0 and sample.cpu.percent <= 100);
    for (sample.cpu.per_core[0..sample.cpu.core_count]) |core| try std.testing.expect(core >= 0 and core <= 100);
    try std.testing.expect(sample.memory.used_mb > 0);
    try std.testing.expect(sample.memory.total_mb >= sample.memory.used_mb);
    try std.testing.expect(sample.memory.percent >= 0 and sample.memory.percent <= 100);
    try std.testing.expectEqual(@as(u64, 2), sampler.sample_calls);
}

test "macOS adapter maps full and empty stream frames into media v2" {
    const root = ".zig-cache/weaver-macos-media-parser";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    var cache = try art_cache.Cache.init(std.testing.io, std.testing.allocator, root);
    defer cache.deinit();
    var provider: MediaProvider = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .script_path = "/weaver/mediaremote-adapter.pl",
        .framework_path = "/weaver/MediaRemoteAdapter.framework",
        .cache = &cache,
    };

    const frame = try provider.parseFrame(
        \\{"type":"data","diff":false,"payload":{"title":"Satellites","artist":"Frost Children","album":"Tweaker Poem","bundleIdentifier":"com.spotify.client","playing":true,"elapsedTime":51.227,"duration":211.0,"artworkData":"Y29tcGxldGUtaW1hZ2U="}}
    );
    try std.testing.expectEqualStrings("Satellites", frame.titleSlice());
    try std.testing.expectEqualStrings("Frost Children", frame.artistSlice());
    try std.testing.expectEqualStrings("Tweaker Poem", frame.albumSlice());
    try std.testing.expectEqualStrings("com.spotify.client", frame.sourceAppSlice());
    try std.testing.expectEqual(media.Status.playing, frame.status);
    try std.testing.expectEqual(@as(u64, 51_227), frame.position_ms);
    try std.testing.expectEqual(@as(u64, 211_000), frame.duration_ms);
    try std.testing.expect(frame.art_path_len > 0);
    const artwork = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        frame.artPathSlice(),
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(artwork);
    try std.testing.expectEqualStrings("complete-image", artwork);

    const empty = try provider.parseFrame(
        \\{"type":"data","diff":false,"payload":{}}
    );
    try std.testing.expectEqual(media.Status.stopped, empty.status);
    try std.testing.expectEqual(@as(usize, 0), empty.title_len);
    try std.testing.expectEqual(@as(usize, 0), empty.art_path_len);
    try std.testing.expectError(
        error.InvalidAdapterFrame,
        provider.parseFrame(
            \\{"type":"data","diff":true,"payload":{"title":"partial"}}
        ),
    );
}

test "macOS adapter loss queues one forced empty frame until recovery" {
    const root = ".zig-cache/weaver-macos-media-loss";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    var cache = try art_cache.Cache.init(std.testing.io, std.testing.allocator, root);
    defer cache.deinit();
    var provider: MediaProvider = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .script_path = "/weaver/mediaremote-adapter.pl",
        .framework_path = "/weaver/MediaRemoteAdapter.framework",
        .cache = &cache,
    };
    provider.setAvailability(.live);
    provider.recordLoss();
    provider.recordLoss();
    const loss = provider.takeFrame().?;
    try std.testing.expect(loss.force);
    try std.testing.expectEqual(media.Status.stopped, loss.frame.status);
    try std.testing.expect(provider.takeFrame() == null);
    try std.testing.expectEqualStrings("unavailable", provider.availabilityLabel());

    var recovered: media.Frame = .{ .status = .paused, .duration_ms = 10_000 };
    media.copyText(&recovered.title, &recovered.title_len, "Recovered");
    provider.publishFrame(recovered);
    const frame = provider.takeFrame().?;
    try std.testing.expect(!frame.force);
    try std.testing.expectEqualStrings("Recovered", frame.frame.titleSlice());
    try std.testing.expectEqualStrings("available", provider.availabilityLabel());
}

test "macOS adapter freezes command IDs seek units clamp and restart bounds" {
    const play = try adapterCommand(.{ .id = 1, .verb = .play }, 0);
    try std.testing.expectEqualStrings("send", play.action);
    try std.testing.expectEqualStrings("0", play.argumentSlice());
    const pause = try adapterCommand(.{ .id = 2, .verb = .pause }, 0);
    try std.testing.expectEqualStrings("1", pause.argumentSlice());
    const next = try adapterCommand(.{ .id = 3, .verb = .next }, 0);
    try std.testing.expectEqualStrings("4", next.argumentSlice());
    const previous = try adapterCommand(.{ .id = 4, .verb = .previous }, 0);
    try std.testing.expectEqualStrings("5", previous.argumentSlice());
    const seek = try adapterCommand(.{ .id = 5, .verb = .seek, .seek_ms = 12_345 }, 10_000);
    try std.testing.expectEqualStrings("seek", seek.action);
    try std.testing.expectEqualStrings("10000000", seek.argumentSlice());
    try std.testing.expectEqual(@as(u64, 1000), media_restart_initial_ms);
    try std.testing.expectEqual(@as(u64, 30_000), media_restart_max_ms);
    try std.testing.expectEqual(@as(i64, 2500), media_command_timeout_ms);
}

test "macOS adapter process failures produce one loss frame and false ack" {
    const root = ".zig-cache/weaver-macos-media-process-failure";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    var cache = try art_cache.Cache.init(std.testing.io, std.testing.allocator, root);
    defer cache.deinit();
    var provider: MediaProvider = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .script_path = "/weaver/does-not-exist/mediaremote-adapter.pl",
        .framework_path = "/weaver/does-not-exist/MediaRemoteAdapter.framework",
        .cache = &cache,
    };
    defer provider.deinit();

    try std.testing.expect(!provider.command(.{ .id = 1, .verb = .play }));
    provider.setActive(true);
    for (0..100) |_| {
        if (std.mem.eql(u8, provider.availabilityLabel(), "unavailable")) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    }
    try std.testing.expectEqualStrings("unavailable", provider.availabilityLabel());
    const loss = provider.takeFrame().?;
    try std.testing.expect(loss.force);
    try std.testing.expect(provider.takeFrame() == null);
    provider.setActive(false);
    try std.testing.expectEqualStrings("idle", provider.availabilityLabel());
}
