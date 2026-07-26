const std = @import("std");
const art_cache = @import("art_cache.zig");
const media = @import("media.zig");
const media_commands = @import("media_commands.zig");
const protocol = @import("provider_protocol.zig");

const c = @cImport({
    @cInclude("macos_system.h");
    @cInclude("poll.h");
});
const posix = std.posix;

pub const media_stream_line_bytes: usize = 2 * 1024 * 1024;
pub const media_restart_initial_ms: u64 = 1000;
pub const media_restart_max_ms: u64 = 30_000;
pub const media_restart_stable_ms: u64 = 30_000;
pub const media_first_frame_deadline_ms: u64 = 10_000;
pub const media_command_timeout_ms: i64 = 2500;
pub const media_stop_grace_ms: u64 = 1000;

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
    elapsedTimeMicros: ?f64 = null,
    elapsedTimeNowMicros: ?f64 = null,
    timestampEpochMicros: ?f64 = null,
    playbackRate: ?f64 = null,
    duration: ?f64 = null,
    durationMicros: ?f64 = null,
    artworkData: ?[]const u8 = null,
};

const QueuedFrame = struct {
    frame: media.Frame,
    force: bool = false,
};

const ParsedAdapterFrame = struct {
    frame: media.Frame,
    playback_rate: f64,
};

const AdapterCommand = struct {
    action: []const u8,
    argument: [32]u8 = @splat(0),
    argument_len: usize,

    fn argumentSlice(self: *const AdapterCommand) []const u8 {
        return self.argument[0..self.argument_len];
    }
};

pub const CommandOutcome = enum { accepted, declined, channel_failure };

pub const CommandResult = struct {
    id: u64,
    outcome: CommandOutcome,
};

/// One executor belongs to one transport-capable Widget. Its single worker
/// preserves that Widget's FIFO order while the host loop remains the sole UDS
/// writer and never waits for a helper process.
pub const MediaCommandExecutor = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    provider: *MediaProvider,
    thread: std.Thread,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    commands: [media_commands.queue_capacity]media_commands.Command = undefined,
    command_head: usize = 0,
    command_count: usize = 0,
    results: [media_commands.queue_capacity]CommandResult = undefined,
    result_head: usize = 0,
    result_count: usize = 0,
    stopping: bool = false,
    self_destroy: bool = false,
    executing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    command_fn: *const fn (*MediaCommandExecutor, media_commands.Command) CommandOutcome = runProviderCommand,

    pub fn start(
        io: std.Io,
        allocator: std.mem.Allocator,
        provider: *MediaProvider,
    ) !*MediaCommandExecutor {
        const self = try allocator.create(MediaCommandExecutor);
        errdefer allocator.destroy(self);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .provider = provider,
            .thread = undefined,
        };
        _ = provider.command_worker_count.fetchAdd(1, .acq_rel);
        errdefer _ = provider.command_worker_count.fetchSub(1, .acq_rel);
        self.thread = try std.Thread.spawn(.{ .stack_size = 128 * 1024 }, threadMain, .{self});
        return self;
    }

    pub fn deinit(self: *MediaCommandExecutor) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        self.thread.join();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Relinquishes host-loop ownership without waiting for an in-flight
    /// helper. The detached worker owns and frees itself after the helper's
    /// existing bounded timeout. MediaProvider tracks detached workers so
    /// process shutdown can prove they have all left before provider teardown.
    pub fn stopDetached(self: *MediaCommandExecutor) void {
        const thread = self.thread;
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.self_destroy = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        thread.detach();
    }

    pub fn submit(self: *MediaCommandExecutor, command: media_commands.Command) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping or self.command_count == self.commands.len) return false;
        const index = (self.command_head + self.command_count) % self.commands.len;
        self.commands[index] = command;
        self.command_count += 1;
        self.condition.signal(self.io);
        return true;
    }

    pub fn takeResult(self: *MediaCommandExecutor) ?CommandResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.result_count == 0) return null;
        const result = self.results[self.result_head];
        self.result_head = (self.result_head + 1) % self.results.len;
        self.result_count -= 1;
        self.condition.signal(self.io);
        return result;
    }

    fn threadMain(self: *MediaCommandExecutor) void {
        defer {
            const provider = self.provider;
            const allocator = self.allocator;
            self.mutex.lockUncancelable(self.io);
            const self_destroy = self.self_destroy;
            self.mutex.unlock(self.io);
            _ = provider.command_worker_count.fetchSub(1, .acq_rel);
            if (self_destroy) allocator.destroy(self);
        }
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.command_count == 0 and !self.stopping) {
                self.condition.waitUncancelable(self.io, &self.mutex);
            }
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const command = self.commands[self.command_head];
            self.command_head = (self.command_head + 1) % self.commands.len;
            self.command_count -= 1;
            self.mutex.unlock(self.io);

            self.executing.store(true, .release);
            const result: CommandResult = .{
                .id = command.id,
                .outcome = self.command_fn(self, command),
            };
            self.executing.store(false, .release);
            self.mutex.lockUncancelable(self.io);
            while (self.result_count == self.results.len and !self.stopping) {
                self.condition.waitUncancelable(self.io, &self.mutex);
            }
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const index = (self.result_head + self.result_count) % self.results.len;
            self.results[index] = result;
            self.result_count += 1;
            self.mutex.unlock(self.io);
        }
    }

    fn runProviderCommand(self: *MediaCommandExecutor, command: media_commands.Command) CommandOutcome {
        return self.provider.command(command);
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
    platform_supported: bool,
    /// Compile-gated automation override for the hosted supervision test.
    /// Shipping builds always leave this null.
    command_test_outcome: ?CommandOutcome = null,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    child_pid: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    attempt_started_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    // 0 = not watching, 1 = awaiting the first frame, 2 = expired.
    // The first frame and the supervision watchdog race through one CAS, so
    // an expired attempt can never publish late data after its loss frame.
    attempt_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    command_worker_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    mutex: std.Io.Mutex = .init,
    availability: MediaAvailability = .idle,
    pending_frame: ?media.Frame = null,
    current_frame: ?media.Frame = null,
    frame_observed_ms: u64 = 0,
    next_timeline_publish_ms: u64 = 0,
    loss_pending: bool = false,
    current_duration_ms: u64 = 0,
    current_playback_rate: f64 = 0,

    pub fn setActive(self: *MediaProvider, active: bool) void {
        if (active) {
            if (!self.platform_supported) {
                self.recordLoss();
                return;
            }
            if (self.thread != null) return;
            self.stopping.store(false, .release);
            self.thread_done.store(false, .release);
            self.setAvailability(.starting);
            self.thread = std.Thread.spawn(.{ .stack_size = media_stream_line_bytes + 512 * 1024 }, streamMain, .{self}) catch {
                self.thread_done.store(true, .release);
                self.recordLoss();
                return;
            };
            return;
        }
        self.stop();
    }

    pub fn deinit(self: *MediaProvider) void {
        self.stop();
        std.debug.assert(self.command_worker_count.load(.acquire) == 0);
    }

    pub fn waitForCommandWorkers(self: *MediaProvider, timeout_ms: u64) bool {
        const deadline = awakeMilliseconds(self.io) +| timeout_ms;
        while (self.command_worker_count.load(.acquire) != 0 and awakeMilliseconds(self.io) < deadline) {
            std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch break;
        }
        return self.command_worker_count.load(.acquire) == 0;
    }

    pub fn takeFrame(self: *MediaProvider, now_ms: u64) ?QueuedFrame {
        self.enforceFirstFrameDeadline(now_ms);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.loss_pending) {
            self.loss_pending = false;
            return .{ .frame = .{}, .force = true };
        }
        if (self.pending_frame) |frame| {
            self.pending_frame = null;
            return .{ .frame = frame };
        }
        var frame = self.current_frame orelse return null;
        if (frame.status != .playing or now_ms < self.next_timeline_publish_ms) return null;
        frame.position_ms = @min(
            if (frame.duration_ms > 0) frame.duration_ms else std.math.maxInt(u64),
            frame.position_ms +| scaledTimelineAdvance(now_ms -| self.frame_observed_ms, self.current_playback_rate),
        );
        self.current_frame = frame;
        self.frame_observed_ms = now_ms;
        self.next_timeline_publish_ms = now_ms + 1000;
        return .{ .frame = frame };
    }

    pub fn availabilityLabel(self: *MediaProvider) []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.availability.label();
    }

    pub fn command(self: *MediaProvider, command_value: media_commands.Command) CommandOutcome {
        if (self.command_test_outcome) |outcome| return outcome;
        // Exit 2 is reserved for a request that reached MediaRemote and was
        // declined. A missing vendored script/framework must not accidentally
        // inherit Perl's own exit-2 convention and resolve false.
        const cwd = std.Io.Dir.cwd();
        const script = cwd.openFile(self.io, self.script_path, .{}) catch return .channel_failure;
        script.close(self.io);
        var framework = cwd.openDir(self.io, self.framework_path, .{}) catch return .channel_failure;
        framework.close(self.io);
        self.mutex.lockUncancelable(self.io);
        const duration_ms = self.current_duration_ms;
        self.mutex.unlock(self.io);
        const invocation = adapterCommand(command_value, duration_ms) catch return .channel_failure;
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "/usr/bin/perl", self.script_path, self.framework_path, invocation.action, invocation.argumentSlice() },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(16 * 1024),
            .timeout = .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(media_command_timeout_ms),
            } },
        }) catch return .channel_failure;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        return classifyCommandResult(result.term, result.stdout);
    }

    fn stop(self: *MediaProvider) void {
        const thread = self.thread orelse {
            self.setAvailability(.idle);
            return;
        };
        self.stopping.store(true, .release);
        self.signalChild(.TERM);
        const graceful_deadline = awakeMilliseconds(self.io) +| media_stop_grace_ms;
        while (!self.thread_done.load(.acquire) and awakeMilliseconds(self.io) < graceful_deadline) {
            std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch break;
            self.signalChild(.TERM);
        }
        if (!self.thread_done.load(.acquire)) {
            self.signalChild(.KILL);
            const kill_deadline = awakeMilliseconds(self.io) +| media_stop_grace_ms;
            while (!self.thread_done.load(.acquire) and awakeMilliseconds(self.io) < kill_deadline) {
                std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch break;
            }
        }
        // The child has either exited cleanly or been forcibly reaped; joining
        // now only releases the already-completed Zig thread.
        thread.join();
        self.thread = null;
        self.child_pid.store(0, .release);
        self.mutex.lockUncancelable(self.io);
        self.pending_frame = null;
        self.current_frame = null;
        self.loss_pending = false;
        self.availability = .idle;
        self.current_duration_ms = 0;
        self.current_playback_rate = 0;
        self.frame_observed_ms = 0;
        self.next_timeline_publish_ms = 0;
        self.mutex.unlock(self.io);
    }

    fn streamMain(self: *MediaProvider) void {
        defer self.thread_done.store(true, .release);
        var backoff_ms = media_restart_initial_ms;
        while (!self.stopping.load(.acquire)) {
            const started_ms = awakeMilliseconds(self.io);
            self.attempt_state.store(1, .release);
            self.attempt_started_ms.store(started_ms, .release);
            var child = std.process.spawn(self.io, .{
                .argv = &.{
                    "/usr/bin/perl",
                    self.script_path,
                    self.framework_path,
                    "stream",
                    "--no-diff",
                    "--debounce=100",
                    "--micros",
                },
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .ignore,
            }) catch {
                self.attempt_state.store(0, .release);
                self.attempt_started_ms.store(0, .release);
                self.recordLoss();
                self.sleepBackoff(backoff_ms);
                backoff_ms = @min(backoff_ms * 2, media_restart_max_ms);
                continue;
            };
            self.child_pid.store(child.id.?, .release);
            if (self.attempt_state.load(.acquire) == 2) {
                child.kill(self.io);
            }
            var malformed = false;
            var saw_frame = false;
            var reader_buffer: [64 * 1024]u8 = undefined;
            var reader = child.stdout.?.reader(self.io, &reader_buffer);
            var pending: [media_stream_line_bytes]u8 = undefined;
            var pending_len: usize = 0;
            var chunk: [64 * 1024]u8 = undefined;
            while (!self.stopping.load(.acquire)) {
                const now_ms = awakeMilliseconds(self.io);
                const poll_timeout_ms = firstFramePollTimeoutMs(started_ms, now_ms, saw_frame);
                if (!saw_frame and poll_timeout_ms.? == 0) {
                    _ = self.attempt_state.cmpxchgStrong(1, 2, .acq_rel, .acquire);
                    malformed = true;
                    break;
                }
                var descriptor: c.struct_pollfd = .{
                    .fd = child.stdout.?.handle,
                    .events = c.POLLIN | c.POLLHUP,
                    .revents = 0,
                };
                // Once the helper has proved the stream with one valid frame,
                // stdout/HUP is the only wake source. The bounded slices below
                // belong solely to the first-frame watchdog; retaining them
                // here would turn an idle media session into a 10 Hz poll.
                const ready = c.poll(&descriptor, 1, if (poll_timeout_ms) |timeout| @intCast(timeout) else -1);
                if (ready < 0) {
                    if (posix.errno(ready) == .INTR) continue;
                    malformed = true;
                    break;
                }
                if (ready == 0) continue;
                const read = reader.interface.readSliceShort(&chunk) catch {
                    malformed = true;
                    break;
                };
                if (read == 0) {
                    if (adapterEofIsProtocolFailure(pending_len)) malformed = true;
                    break;
                }
                if (read > pending.len - pending_len) {
                    malformed = true;
                    break;
                }
                @memcpy(pending[pending_len..][0..read], chunk[0..read]);
                pending_len += read;
                var start: usize = 0;
                while (std.mem.indexOfScalarPos(u8, pending[0..pending_len], start, '\n')) |end| {
                    const frame_now_ms = awakeMilliseconds(self.io);
                    const frame = self.parseFrameAt(
                        pending[start..end],
                        frame_now_ms,
                        realEpochMicroseconds(self.io),
                    ) catch {
                        malformed = true;
                        break;
                    };
                    if (!saw_frame) {
                        if (self.attempt_state.cmpxchgStrong(1, 0, .acq_rel, .acquire) != null) {
                            malformed = true;
                            break;
                        }
                        self.attempt_started_ms.store(0, .release);
                    }
                    saw_frame = true;
                    self.publishFrameAtRate(frame.frame, frame.playback_rate, frame_now_ms);
                    start = end + 1;
                }
                if (malformed) break;
                if (start > 0) {
                    std.mem.copyForwards(u8, pending[0 .. pending_len - start], pending[start..pending_len]);
                    pending_len -= start;
                }
            }
            if (malformed and child.id != null) child.kill(self.io);
            if (child.id != null) _ = child.wait(self.io) catch {};
            self.child_pid.store(0, .release);
            self.attempt_state.store(0, .release);
            self.attempt_started_ms.store(0, .release);
            if (self.stopping.load(.acquire)) break;
            self.recordLoss();
            backoff_ms = restartBackoff(backoff_ms, awakeMilliseconds(self.io) -| started_ms, saw_frame);
            self.sleepBackoff(backoff_ms);
            backoff_ms = @min(backoff_ms * 2, media_restart_max_ms);
        }
    }

    fn enforceFirstFrameDeadline(self: *MediaProvider, now_ms: u64) void {
        if (self.attempt_state.load(.acquire) != 1) return;
        const started_ms = self.attempt_started_ms.load(.acquire);
        if (started_ms == 0 or now_ms -| started_ms < media_first_frame_deadline_ms) return;
        if (self.attempt_state.cmpxchgStrong(1, 2, .acq_rel, .acquire) != null) return;
        // This runs on the existing 1 Hz host provider supervision tick, so it
        // remains effective even if the stream worker is stuck in spawn,
        // poll, or read. The loss frame is published immediately; killing the
        // child releases the worker into the existing bounded backoff path.
        self.signalChild(.KILL);
        self.recordLoss();
    }

    fn parseFrameAt(
        self: *MediaProvider,
        line: []const u8,
        now_ms: u64,
        now_epoch_micros: u64,
    ) !ParsedAdapterFrame {
        const parsed = try std.json.parseFromSlice(StreamEnvelope, self.allocator, line, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.type, "data") or parsed.value.diff) return error.InvalidAdapterFrame;
        const payload = parsed.value.payload;
        const title = payload.title orelse "";
        const has_session = payload.title != null or
            payload.artist != null or
            payload.album != null or
            payload.bundleIdentifier != null or
            payload.playing != null or
            payload.elapsedTime != null or
            payload.elapsedTimeNow != null or
            payload.elapsedTimeMicros != null or
            payload.elapsedTimeNowMicros != null or
            payload.timestampEpochMicros != null or
            payload.playbackRate != null or
            payload.duration != null or
            payload.durationMicros != null or
            payload.artworkData != null;
        if (!has_session) {
            self.cache.clearPublished();
            return .{ .frame = .{}, .playback_rate = 0 };
        }
        const playback_rate = try adapterPlaybackRate(payload);
        const position_micros = timelinePositionMicros(payload, now_epoch_micros, playback_rate);
        var frame: media.Frame = .{
            .status = if (payload.playing) |playing|
                if (playing) .playing else .paused
            else
                .stopped,
            .position_ms = if (position_micros) |value| microsecondsToMilliseconds(value) else 0,
            .duration_ms = if (payload.durationMicros) |value|
                microsecondsToMilliseconds(value)
            else
                secondsToMilliseconds(payload.duration orelse 0),
        };
        media.copyText(&frame.title, &frame.title_len, title);
        media.copyText(&frame.artist, &frame.artist_len, payload.artist orelse "");
        media.copyText(&frame.album, &frame.album_len, payload.album orelse "");
        media.copyText(&frame.source_app, &frame.source_app_len, payload.bundleIdentifier orelse "");
        if (payload.artworkData) |encoded| {
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
                return error.InvalidAdapterArtwork;
            if (decoded_len == 0 or decoded_len > art_cache.max_input_bytes)
                return error.InvalidAdapterArtwork;
            const decoded = try self.allocator.alloc(u8, decoded_len);
            defer self.allocator.free(decoded);
            std.base64.standard.Decoder.decode(decoded, encoded) catch
                return error.InvalidAdapterArtwork;
            var normalized: ?[*]u8 = null;
            var normalized_len: usize = 0;
            var width: u32 = 0;
            var height: u32 = 0;
            if (c.weaver_macos_normalize_artwork(
                decoded.ptr,
                decoded.len,
                &normalized,
                &normalized_len,
                &width,
                &height,
            ) != 1 or normalized == null or normalized_len == 0 or
                normalized_len > art_cache.max_input_bytes or
                @as(u64, width) * height * 4 > 256 * 1024)
            {
                if (normalized) |bytes| c.weaver_macos_free_artwork(bytes);
                return error.InvalidAdapterArtwork;
            }
            defer c.weaver_macos_free_artwork(normalized.?);
            const publication = (try self.cache.publish(normalized.?[0..normalized_len])) orelse
                return error.InvalidAdapterArtwork;
            media.copyText(&frame.art_path, &frame.art_path_len, publication.pathSlice());
        } else {
            self.cache.clearPublished();
        }
        _ = now_ms;
        return .{ .frame = frame, .playback_rate = playback_rate };
    }

    fn publishFrame(self: *MediaProvider, frame: media.Frame, now_ms: u64) void {
        self.publishFrameAtRate(frame, if (frame.status == .playing) 1 else 0, now_ms);
    }

    fn publishFrameAtRate(self: *MediaProvider, frame: media.Frame, playback_rate: f64, now_ms: u64) void {
        self.mutex.lockUncancelable(self.io);
        self.pending_frame = frame;
        self.current_frame = frame;
        self.frame_observed_ms = now_ms;
        self.next_timeline_publish_ms = now_ms + 1000;
        self.current_duration_ms = frame.duration_ms;
        self.current_playback_rate = playback_rate;
        self.availability = .live;
        self.mutex.unlock(self.io);
    }

    fn recordLoss(self: *MediaProvider) void {
        self.cache.clearPublished();
        self.mutex.lockUncancelable(self.io);
        if (self.availability != .unavailable) self.loss_pending = true;
        self.pending_frame = null;
        self.current_frame = null;
        self.current_duration_ms = 0;
        self.current_playback_rate = 0;
        self.frame_observed_ms = 0;
        self.next_timeline_publish_ms = 0;
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

    fn signalChild(self: *MediaProvider, signal: posix.SIG) void {
        const pid = self.child_pid.load(.acquire);
        if (pid > 0) posix.kill(pid, signal) catch {};
    }
};

fn secondsToMilliseconds(seconds: f64) u64 {
    if (!std.math.isFinite(seconds) or seconds <= 0) return 0;
    const milliseconds = seconds * 1000.0;
    if (milliseconds >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
    return @intFromFloat(@round(milliseconds));
}

fn microsecondsToMilliseconds(microseconds: f64) u64 {
    if (!std.math.isFinite(microseconds) or microseconds <= 0) return 0;
    const milliseconds = microseconds / 1000.0;
    if (milliseconds >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
    return @intFromFloat(@round(milliseconds));
}

fn adapterPlaybackRate(payload: Payload) !f64 {
    const rate: f64 = payload.playbackRate orelse if (payload.playing == true) 1.0 else 0.0;
    if (!std.math.isFinite(rate) or rate < 0 or rate > 16) return error.InvalidAdapterPlaybackRate;
    return rate;
}

fn timelinePositionMicros(payload: Payload, now_epoch_micros: u64, playback_rate: f64) ?f64 {
    if (payload.elapsedTimeNowMicros) |value| return value;
    if (payload.elapsedTimeMicros) |elapsed| {
        if (payload.playing == true) {
            if (payload.timestampEpochMicros) |timestamp| {
                const now: f64 = @floatFromInt(now_epoch_micros);
                return elapsed + @max(0, now - timestamp) * playback_rate;
            }
        }
        return elapsed;
    }
    if (payload.elapsedTimeNow) |value| return value * 1_000_000.0;
    if (payload.elapsedTime) |value| return value * 1_000_000.0;
    return null;
}

fn scaledTimelineAdvance(elapsed_ms: u64, playback_rate: f64) u64 {
    if (elapsed_ms == 0 or playback_rate <= 0 or !std.math.isFinite(playback_rate)) return 0;
    const scaled = @as(f64, @floatFromInt(elapsed_ms)) * playback_rate;
    if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
    return @intFromFloat(@round(scaled));
}

fn firstFramePollTimeoutMs(started_ms: u64, now_ms: u64, saw_frame: bool) ?u64 {
    if (saw_frame) return null;
    const elapsed = now_ms -| started_ms;
    if (elapsed >= media_first_frame_deadline_ms) return 0;
    return @min(media_first_frame_deadline_ms - elapsed, 100);
}

fn classifyCommandResult(term: std.process.Child.Term, stdout: []const u8) CommandOutcome {
    return switch (term) {
        .exited => |code| if (stdout.len != 0)
            .channel_failure
        else if (code == 0)
            .accepted
        else if (code == 2)
            .declined
        else
            .channel_failure,
        else => .channel_failure,
    };
}

fn restartBackoff(current_ms: u64, streamed_ms: u64, saw_frame: bool) u64 {
    return if (saw_frame and streamed_ms >= media_restart_stable_ms)
        media_restart_initial_ms
    else
        current_ms;
}

fn mediaFloorAllows(major: u64, minor: u64) bool {
    return major > 15 or (major == 15 and minor >= 4);
}

fn adapterEofIsProtocolFailure(pending_len: usize) bool {
    return pending_len != 0;
}

fn awakeMilliseconds(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Timestamp.now(io, .awake).nanoseconds) / std.time.ns_per_ms);
}

fn realEpochMicroseconds(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Timestamp.now(io, .real).nanoseconds) / std.time.ns_per_us);
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

fn slowCommandTestSeam(executor: *MediaCommandExecutor, _: media_commands.Command) CommandOutcome {
    std.Io.sleep(executor.io, .fromMilliseconds(300), .awake) catch {};
    return .declined;
}

test "media command executor teardown never joins an in-flight helper on the supervision loop" {
    var provider: MediaProvider = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .script_path = "",
        .framework_path = "",
        .cache = undefined,
        .platform_supported = false,
    };
    const executor = try MediaCommandExecutor.start(std.testing.io, std.testing.allocator, &provider);
    executor.command_fn = slowCommandTestSeam;
    try std.testing.expect(executor.submit(.{ .id = 1, .verb = .play }));
    for (0..100) |_| {
        if (executor.executing.load(.acquire)) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
    try std.testing.expect(executor.executing.load(.acquire));

    const started_ms = awakeMilliseconds(std.testing.io);
    executor.stopDetached();
    try std.testing.expect(awakeMilliseconds(std.testing.io) -| started_ms < 100);
    try std.testing.expect(provider.waitForCommandWorkers(1000));
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
        .platform_supported = true,
    };

    const parsed_frame = try provider.parseFrameAt(
        \\{"type":"data","diff":false,"payload":{"title":"Satellites","artist":"Frost Children","album":"Tweaker Poem","bundleIdentifier":"com.spotify.client","playing":true,"playbackRate":2,"elapsedTimeMicros":51000000,"timestampEpochMicros":1700000000000000,"durationMicros":211000000}}
    ,
        10_000,
        1_700_000_000_227_000,
    );
    const frame = parsed_frame.frame;
    try std.testing.expectEqualStrings("Satellites", frame.titleSlice());
    try std.testing.expectEqualStrings("Frost Children", frame.artistSlice());
    try std.testing.expectEqualStrings("Tweaker Poem", frame.albumSlice());
    try std.testing.expectEqualStrings("com.spotify.client", frame.sourceAppSlice());
    try std.testing.expectEqual(media.Status.playing, frame.status);
    try std.testing.expectEqual(@as(u64, 51_454), frame.position_ms);
    try std.testing.expectEqual(@as(f64, 2), parsed_frame.playback_rate);
    try std.testing.expectEqual(@as(u64, 211_000), frame.duration_ms);

    const blank_title = (try provider.parseFrameAt(
        \\{"type":"data","diff":false,"payload":{"title":"","bundleIdentifier":"com.spotify.client"}}
    ,
        10_000,
        1_700_000_000_227_000,
    )).frame;
    try std.testing.expectEqual(@as(usize, 0), blank_title.title_len);
    try std.testing.expectEqualStrings("com.spotify.client", blank_title.sourceAppSlice());
    try std.testing.expectEqual(media.Status.stopped, blank_title.status);

    const empty = (try provider.parseFrameAt(
        \\{"type":"data","diff":false,"payload":{}}
    ,
        10_000,
        1_700_000_000_227_000,
    )).frame;
    try std.testing.expectEqual(media.Status.stopped, empty.status);
    try std.testing.expectEqual(@as(usize, 0), empty.title_len);
    try std.testing.expectEqual(@as(usize, 0), empty.art_path_len);
    try std.testing.expectError(
        error.InvalidAdapterFrame,
        provider.parseFrameAt(
            \\{"type":"data","diff":true,"payload":{"title":"partial"}}
        ,
            10_000,
            1_700_000_000_227_000,
        ),
    );
}

test "macOS 300x300 artwork is normalized to the shared image budget" {
    const root = ".zig-cache/weaver-macos-media-art-normalization";
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
        .platform_supported = true,
    };
    const frame = (try provider.parseFrameAt(
        \\{"type":"data","diff":false,"payload":{"title":"Artwork","playing":false,"artworkData":"iVBORw0KGgoAAAANSUhEUgAAASwAAAEsCAYAAAB5fY51AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAPwSURBVHe7dQxDQAgAMAwxGIJmWiAHwUs6dFnAjbm2gegYLwB4FeGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGFYQIZhARmGBWQYFpBhWECGYQEZhgVkGBaQYVhAhmEBGYYFZBgWkGHEBYmXXaN2gGYQAAAAASUVORK5CYII="}}
    ,
        100,
        1_700_000_000_000_000,
    )).frame;
    try std.testing.expect(frame.art_path_len > 0);
    const artwork = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        frame.artPathSlice(),
        std.testing.allocator,
        .limited(art_cache.max_input_bytes),
    );
    defer std.testing.allocator.free(artwork);
    try std.testing.expect(artwork.len <= art_cache.max_input_bytes);
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", artwork[0..8]);

    try std.testing.expectError(
        error.InvalidAdapterArtwork,
        provider.parseFrameAt(
            \\{"type":"data","diff":false,"payload":{"title":"Broken","artworkData":"%%%"}}
        ,
            200,
            1_700_000_000_000_000,
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
        .platform_supported = true,
    };
    provider.setAvailability(.live);
    provider.recordLoss();
    provider.recordLoss();
    const loss = provider.takeFrame(0).?;
    try std.testing.expect(loss.force);
    try std.testing.expectEqual(media.Status.stopped, loss.frame.status);
    try std.testing.expect(provider.takeFrame(0) == null);
    try std.testing.expectEqualStrings("unavailable", provider.availabilityLabel());

    var recovered: media.Frame = .{ .status = .paused, .duration_ms = 10_000 };
    media.copyText(&recovered.title, &recovered.title_len, "Recovered");
    provider.publishFrame(recovered, 100);
    const frame = provider.takeFrame(100).?;
    try std.testing.expect(!frame.force);
    try std.testing.expectEqualStrings("Recovered", frame.frame.titleSlice());
    try std.testing.expectEqualStrings("available", provider.availabilityLabel());

    recovered.status = .playing;
    recovered.position_ms = 1000;
    provider.publishFrameAtRate(recovered, 2, 1000);
    _ = provider.takeFrame(1000).?;
    try std.testing.expect(provider.takeFrame(1999) == null);
    const advanced = provider.takeFrame(2000).?;
    try std.testing.expectEqual(@as(u64, 3000), advanced.frame.position_ms);
}

test "macOS adapter validates playback rate and bounds its first-frame watchdog" {
    const root = ".zig-cache/weaver-macos-media-rate";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    var cache = try art_cache.Cache.init(std.testing.io, std.testing.allocator, root);
    defer cache.deinit();
    var provider: MediaProvider = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .script_path = "",
        .framework_path = "",
        .cache = &cache,
        .platform_supported = true,
    };
    try std.testing.expectError(
        error.InvalidAdapterPlaybackRate,
        provider.parseFrameAt(
            \\{"type":"data","diff":false,"payload":{"title":"Bad rate","playing":true,"playbackRate":20}}
        ,
            0,
            0,
        ),
    );
    try std.testing.expectEqual(@as(?u64, 100), firstFramePollTimeoutMs(1000, 1000, false));
    try std.testing.expectEqual(@as(?u64, 1), firstFramePollTimeoutMs(1000, 10_999, false));
    try std.testing.expectEqual(@as(?u64, 0), firstFramePollTimeoutMs(1000, 11_000, false));

    provider.setAvailability(.starting);
    provider.attempt_state.store(1, .release);
    provider.attempt_started_ms.store(1000, .release);
    try std.testing.expect(provider.takeFrame(10_999) == null);
    const watchdog_loss = provider.takeFrame(11_000).?;
    try std.testing.expect(watchdog_loss.force);
    try std.testing.expectEqual(@as(u8, 2), provider.attempt_state.load(.acquire));
    try std.testing.expectEqualStrings("unavailable", provider.availabilityLabel());
}

test "macOS adapter has no post-frame idle timeout wakeups" {
    // A null timeout maps to poll(2)'s infinite wait. Advancing the monotonic
    // clock cannot manufacture work after the first valid frame; only new
    // stdout bytes or HUP can wake the stream worker.
    for ([_]u64{ 1000, 1100, 11_000, 99_000, std.math.maxInt(u64) }) |now_ms| {
        try std.testing.expectEqual(@as(?u64, null), firstFramePollTimeoutMs(1000, now_ms, true));
    }
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
    try std.testing.expectEqual(@as(u64, 30_000), media_restart_stable_ms);
    try std.testing.expectEqual(@as(i64, 2500), media_command_timeout_ms);
}

test "macOS command taxonomy rejects helper failures and declines only exit 2" {
    try std.testing.expectEqual(
        CommandOutcome.accepted,
        classifyCommandResult(.{ .exited = 0 }, ""),
    );
    try std.testing.expectEqual(
        CommandOutcome.declined,
        classifyCommandResult(.{ .exited = 2 }, ""),
    );
    try std.testing.expectEqual(
        CommandOutcome.channel_failure,
        classifyCommandResult(.{ .exited = 1 }, ""),
    );
    try std.testing.expectEqual(
        CommandOutcome.channel_failure,
        classifyCommandResult(.{ .signal = .KILL }, ""),
    );
    try std.testing.expectEqual(
        CommandOutcome.channel_failure,
        classifyCommandResult(.{ .exited = 0 }, "unexpected"),
    );
}

test "macOS no-session seek is a decline and never verified success" {
    try std.testing.expectEqual(
        CommandOutcome.declined,
        classifyCommandResult(.{ .exited = 2 }, ""),
    );
}

test "macOS restart backoff needs thirty seconds of stable streaming" {
    try std.testing.expectEqual(@as(u64, 8000), restartBackoff(8000, 29_999, true));
    try std.testing.expectEqual(@as(u64, 8000), restartBackoff(8000, 30_000, false));
    try std.testing.expectEqual(@as(u64, 1000), restartBackoff(8000, 30_000, true));
}

test "macOS adapter discards an unterminated record at EOF" {
    try std.testing.expect(!adapterEofIsProtocolFailure(0));
    try std.testing.expect(adapterEofIsProtocolFailure(1));
    try std.testing.expect(adapterEofIsProtocolFailure(media_stream_line_bytes - 1));
}

test "macOS media floor rejects 15.3 and accepts 15.4" {
    try std.testing.expect(!mediaFloorAllows(15, 3));
    try std.testing.expect(mediaFloorAllows(15, 4));
    try std.testing.expect(mediaFloorAllows(16, 0));
}

test "macOS adapter process failures produce one loss frame and channel rejection" {
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
        .platform_supported = true,
    };
    defer provider.deinit();

    var executor = try MediaCommandExecutor.start(std.testing.io, std.testing.allocator, &provider);
    defer executor.deinit();
    try std.testing.expect(executor.submit(.{ .id = 1, .verb = .play }));
    try std.testing.expect(executor.submit(.{ .id = 2, .verb = .pause }));
    var results: [2]CommandResult = undefined;
    var result_count: usize = 0;
    for (0..100) |_| {
        while (executor.takeResult()) |result| {
            results[result_count] = result;
            result_count += 1;
        }
        if (result_count == results.len) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    }
    try std.testing.expectEqual(@as(usize, 2), result_count);
    try std.testing.expectEqual(@as(u64, 1), results[0].id);
    try std.testing.expectEqual(CommandOutcome.channel_failure, results[0].outcome);
    try std.testing.expectEqual(@as(u64, 2), results[1].id);
    try std.testing.expectEqual(CommandOutcome.channel_failure, results[1].outcome);

    provider.setActive(true);
    for (0..100) |_| {
        if (std.mem.eql(u8, provider.availabilityLabel(), "unavailable")) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    }
    try std.testing.expectEqualStrings("unavailable", provider.availabilityLabel());
    const loss = provider.takeFrame(0).?;
    try std.testing.expect(loss.force);
    try std.testing.expect(provider.takeFrame(0) == null);
    provider.setActive(false);
    try std.testing.expectEqualStrings("idle", provider.availabilityLabel());
}

test "macOS platform floor keeps media unavailable without spawning helper" {
    const root = ".zig-cache/weaver-macos-media-floor";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    var cache = try art_cache.Cache.init(std.testing.io, std.testing.allocator, root);
    defer cache.deinit();
    var provider: MediaProvider = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .script_path = "/must/not/spawn",
        .framework_path = "/must/not/spawn",
        .cache = &cache,
        .platform_supported = false,
    };
    provider.setActive(true);
    try std.testing.expect(provider.thread == null);
    try std.testing.expectEqualStrings("unavailable", provider.availabilityLabel());
    try std.testing.expect(provider.takeFrame(0).?.force);
    provider.setActive(false);
}
