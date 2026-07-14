const std = @import("std");
const audio = @import("audio.zig");
const backoff = @import("backoff.zig");
const media = @import("media.zig");
const providers = @import("providers.zig");
const registry = @import("registry.zig");

const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("psapi.h");
    @cInclude("tlhelp32.h");
});

const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostSingletonV2");
const shutdown_event_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostShutdownV2");
const reload_event_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostReloadV2");
const env_pipe_name = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_HOST_PIPE");
const env_backend_file = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_BACKEND_FILE");
const env_renderer_pipe = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_RENDERER_PIPE");
const env_renderer_log = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_RENDERER_LOG");
const max_widgets: usize = 32;
const max_name_bytes: usize = 128;
const max_path_bytes: usize = 2048;
const invalid_handle = c.INVALID_HANDLE_VALUE;

const RunState = enum { disabled, starting, running, backoff, stopped, source_missing };

fn runStateLabel(state: RunState) []const u8 {
    return if (state == .source_missing) "source missing" else @tagName(state);
}

const Slot = struct {
    used: bool = false,
    enabled: bool = false,
    name_buffer: [max_name_bytes]u8 = undefined,
    name_len: usize = 0,
    source_buffer: [max_path_bytes]u8 = undefined,
    source_len: usize = 0,
    state: RunState = .disabled,
    process: c.HANDLE = null,
    pid: u32 = 0,
    pipe: c.HANDLE = invalid_handle,
    wants_cpu: bool = false,
    wants_memory: bool = false,
    wants_audio: bool = false,
    wants_media: bool = false,
    wants_gpu: bool = false,
    cpu_sent: bool = false,
    memory_sent: bool = false,
    media_sent: bool = false,
    artifact_mtime: i128 = 0,
    started_ms: u64 = 0,
    next_restart_ms: u64 = 0,
    crash_times: [backoff.history_capacity]u64 = [_]u64{0} ** backoff.history_capacity,
    crash_count: usize = 0,
    reason_buffer: [256]u8 = undefined,
    reason_len: usize = 0,
    previous_process_ticks: u64 = 0,
    previous_sample_ms: u64 = 0,
    private_samples: [15]u64 = [_]u64{0} ** 15,
    cpu_samples: [15]f64 = [_]f64{0} ** 15,
    sample_count: usize = 0,
    sample_cursor: usize = 0,
    backend_path_buffer: [max_path_bytes]u8 = undefined,
    backend_path_len: usize = 0,

    fn name(self: *const Slot) []const u8 { return self.name_buffer[0..self.name_len]; }
    fn source(self: *const Slot) []const u8 { return self.source_buffer[0..self.source_len]; }
    fn reason(self: *const Slot) []const u8 { return self.reason_buffer[0..self.reason_len]; }
    fn backendPath(self: *const Slot) []const u8 { return self.backend_path_buffer[0..self.backend_path_len]; }

    fn setRegistration(self: *Slot, value: registry.Registration) !void {
        if (value.name.len > self.name_buffer.len or value.sourcePath.len > self.source_buffer.len) return error.RegistrationTooLong;
        @memcpy(self.name_buffer[0..value.name.len], value.name);
        @memcpy(self.source_buffer[0..value.sourcePath.len], value.sourcePath);
        self.name_len = value.name.len;
        self.source_len = value.sourcePath.len;
        self.enabled = value.enabled;
        self.used = true;
        if (!value.enabled) self.state = .disabled;
    }

    fn setReason(self: *Slot, comptime format: []const u8, args: anytype) void {
        var writer = std.Io.Writer.fixed(&self.reason_buffer);
        writer.print(format, args) catch {};
        self.reason_len = writer.buffered().len;
    }

    fn averages(self: *const Slot) struct { private_mb: f64, cpu: f64 } {
        if (self.sample_count == 0) return .{ .private_mb = 0, .cpu = 0 };
        var private_total: u64 = 0;
        var cpu_total: f64 = 0;
        for (self.private_samples[0..self.sample_count]) |value| private_total += value;
        for (self.cpu_samples[0..self.sample_count]) |value| cpu_total += value;
        return .{
            .private_mb = @as(f64, @floatFromInt(private_total)) / @as(f64, @floatFromInt(self.sample_count)) / (1024.0 * 1024.0),
            .cpu = cpu_total / @as(f64, @floatFromInt(self.sample_count)),
        };
    }
};

const RendererState = struct {
    process: c.HANDLE = null,
    pid: u32 = 0,
    started_ms: u64 = 0,
    next_restart_ms: u64 = 0,
    crash_count: usize = 0,
    previous_process_ticks: u64 = 0,
    previous_sample_ms: u64 = 0,
    private_samples: [15]u64 = [_]u64{0} ** 15,
    cpu_samples: [15]f64 = [_]f64{0} ** 15,
    sample_count: usize = 0,
    sample_cursor: usize = 0,

    fn averages(self: *const RendererState) struct { private_mb: f64, cpu: f64 } {
        if (self.sample_count == 0) return .{ .private_mb = 0, .cpu = 0 };
        var private_total: u64 = 0;
        var cpu_total: f64 = 0;
        for (self.private_samples[0..self.sample_count]) |value| private_total += value;
        for (self.cpu_samples[0..self.sample_count]) |value| cpu_total += value;
        return .{
            .private_mb = @as(f64, @floatFromInt(private_total)) / @as(f64, @floatFromInt(self.sample_count)) / (1024.0 * 1024.0),
            .cpu = cpu_total / @as(f64, @floatFromInt(self.sample_count)),
        };
    }
};

const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    registry_path: []const u8,
    status_path: []const u8,
    status_temp_path: []const u8,
    runtime_exe: []const u8,
    renderer_exe: []const u8,
    renderer_pipe_name: []const u8,
    renderer_log_path: []const u8,
    cli_script: []const u8,
    force_software: bool,
    renderer: RendererState = .{},
    slots: [max_widgets]Slot = [_]Slot{.{}} ** max_widgets,
    sampler: providers.Sampler = .{},
    audio_provider: audio.Provider = .{},
    media_provider: media.Provider = .{},
    previous_cpu: [8192]u8 = undefined,
    previous_cpu_len: usize = 0,
    previous_memory: [512]u8 = undefined,
    previous_memory_len: usize = 0,
    previous_media: [2048]u8 = undefined,
    previous_media_len: usize = 0,
    audio_pipe_frames: u64 = 0,
    media_pipe_frames: u64 = 0,
    thread_sample_ms: u64 = 0,
    slot_threads: [max_widgets]u32 = [_]u32{0} ** max_widgets,
    renderer_threads: u32 = 0,

    fn loadRegistry(self: *Host) !void {
        const owned_bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.registry_path, self.allocator, .limited(256 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (owned_bytes) |bytes| self.allocator.free(bytes);
        const bytes = owned_bytes orelse "{\"widgets\":[]}";
        const parsed = try registry.parse(self.allocator, bytes);
        defer parsed.deinit();
        var seen = [_]bool{false} ** max_widgets;
        for (parsed.value.widgets) |registration| {
            const index = findSlot(&self.slots, registration.name) orelse findFreeSlot(&self.slots) orelse return error.RegistryFull;
            seen[index] = true;
            const slot = &self.slots[index];
            const source_changed = slot.used and !std.mem.eql(u8, slot.source(), registration.sourcePath);
            if (source_changed) self.stopSlot(slot, true);
            try slot.setRegistration(registration);
            if (!registration.enabled and slot.process != null) self.stopSlot(slot, true);
            if (!registration.enabled) slot.state = .disabled;
            if (registration.enabled and slot.state == .disabled) slot.state = .starting;
            const artifact = self.artifactMtime(slot.source());
            if (slot.process != null and artifact != 0 and artifact != slot.artifact_mtime) {
                self.stopSlot(slot, true);
                slot.state = .starting;
            }
        }
        for (&self.slots, 0..) |*slot, index| {
            if (!slot.used or seen[index]) continue;
            self.stopSlot(slot, true);
            slot.* = .{};
        }
    }

    fn supervise(self: *Host, now_ms: u64) void {
        self.superviseRenderer(now_ms);
        for (&self.slots) |*slot| {
            if (!slot.used or !slot.enabled) continue;
            if (!self.sourceExists(slot.source())) {
                if (slot.process != null) self.stopSlot(slot, true);
                slot.state = .source_missing;
                slot.next_restart_ms = 0;
                slot.setReason("registered source path does not exist", .{});
                continue;
            }
            if (slot.state == .source_missing) {
                slot.state = .starting;
                slot.reason_len = 0;
            }
            if (slot.state == .stopped) continue;
            if (slot.process) |process| {
                if (c.WaitForSingleObject(process, 0) == c.WAIT_OBJECT_0) self.handleExit(slot, now_ms);
                continue;
            }
            if ((slot.state == .starting or slot.state == .backoff) and now_ms >= slot.next_restart_ms) {
                self.launch(slot, now_ms) catch |err| {
                    slot.setReason("launch failed: {s}", .{@errorName(err)});
                    self.recordCrash(slot, now_ms, null);
                };
            }
        }
        self.superviseRenderer(now_ms);
    }

    fn launch(self: *Host, slot: *Slot, now_ms: u64) !void {
        try self.ensureBundle(slot.source());
        const dist = try std.fs.path.join(self.allocator, &.{ slot.source(), "dist" });
        defer self.allocator.free(dist);
        const manifest_path = try std.fs.path.join(self.allocator, &.{ dist, "widget.json" });
        defer self.allocator.free(manifest_path);
        const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, manifest_path, self.allocator, .limited(64 * 1024));
        defer self.allocator.free(manifest_bytes);
        const Manifest = struct {
            subscribe: []const []const u8 = &.{},
            renderBackend: []const u8 = "software",
        };
        const manifest = try std.json.parseFromSlice(Manifest, self.allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
        defer manifest.deinit();
        slot.wants_cpu = false;
        slot.wants_memory = false;
        slot.wants_audio = false;
        slot.wants_media = false;
        slot.wants_gpu = !self.force_software and std.mem.eql(u8, manifest.value.renderBackend, "gpu");
        for (manifest.value.subscribe) |name| {
            if (std.mem.eql(u8, name, "cpu")) slot.wants_cpu = true;
            if (std.mem.eql(u8, name, "memory")) slot.wants_memory = true;
            if (std.mem.eql(u8, name, "audio")) slot.wants_audio = true;
            if (std.mem.eql(u8, name, "media")) slot.wants_media = true;
        }
        if (slot.wants_gpu) self.ensureRenderer(now_ms) catch {};
        var pipe_name_buffer: [256]u8 = undefined;
        var pipe_name: []const u8 = &.{};
        if (slot.wants_cpu or slot.wants_memory or slot.wants_audio or slot.wants_media) {
            pipe_name = try std.fmt.bufPrint(&pipe_name_buffer, "\\\\.\\pipe\\weaver-{d}-{x}", .{ c.GetCurrentProcessId(), std.hash.Wyhash.hash(now_ms, slot.name()) });
            const pipe_name_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, pipe_name);
            defer self.allocator.free(pipe_name_w);
            slot.pipe = c.CreateNamedPipeW(pipe_name_w.ptr, c.PIPE_ACCESS_OUTBOUND, c.PIPE_TYPE_BYTE | c.PIPE_READMODE_BYTE | c.PIPE_NOWAIT, 1, 8192, 8192, 0, null);
            if (slot.pipe == invalid_handle) return error.CreatePipeFailed;
        }
        errdefer self.closePipe(slot);
        const command = try std.fmt.allocPrint(self.allocator, "\"{s}\" \"{s}\"", .{ self.runtime_exe, dist });
        defer self.allocator.free(command);
        const command_w_const = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, command);
        defer self.allocator.free(command_w_const);
        const command_w = try self.allocator.dupeZ(u16, command_w_const);
        defer self.allocator.free(command_w);
        if (pipe_name.len > 0) {
            const value_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, pipe_name);
            defer self.allocator.free(value_w);
            if (c.SetEnvironmentVariableW(env_pipe_name, value_w.ptr) == 0) return error.SetEnvironmentFailed;
        }
        if (slot.wants_gpu) {
            const renderer_pipe_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, self.renderer_pipe_name);
            defer self.allocator.free(renderer_pipe_w);
            if (c.SetEnvironmentVariableW(env_renderer_pipe, renderer_pipe_w.ptr) == 0) return error.SetEnvironmentFailed;
        }
        const backend_hash = std.hash.Wyhash.hash(0, slot.name());
        const backend_path = try std.fmt.bufPrint(&slot.backend_path_buffer, "{s}.backend-{x}", .{ self.status_path, backend_hash });
        slot.backend_path_len = backend_path.len;
        std.Io.Dir.cwd().deleteFile(self.io, backend_path) catch {};
        const backend_path_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, backend_path);
        defer self.allocator.free(backend_path_w);
        if (c.SetEnvironmentVariableW(env_backend_file, backend_path_w.ptr) == 0) return error.SetEnvironmentFailed;
        defer {
            if (pipe_name.len > 0) _ = c.SetEnvironmentVariableW(env_pipe_name, null);
            if (slot.wants_gpu) _ = c.SetEnvironmentVariableW(env_renderer_pipe, null);
            _ = c.SetEnvironmentVariableW(env_backend_file, null);
        }
        var startup: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
        startup.cb = @sizeOf(c.STARTUPINFOW);
        var process_info: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);
        if (c.CreateProcessW(null, command_w.ptr, null, null, 0, c.CREATE_NO_WINDOW, null, null, &startup, &process_info) == 0) return error.CreateProcessFailed;
        _ = c.CloseHandle(process_info.hThread);
        slot.process = process_info.hProcess;
        slot.pid = process_info.dwProcessId;
        self.thread_sample_ms = 0;
        if (slot.pipe != invalid_handle) {
            if (!connectPipe(slot.pipe, slot.process, 5_000)) {
                _ = c.TerminateProcess(slot.process, 1);
                return error.ConnectPipeFailed;
            }
        }
        slot.state = .running;
        slot.started_ms = now_ms;
        slot.reason_len = 0;
        slot.artifact_mtime = self.artifactMtime(slot.source());
        slot.previous_process_ticks = processTicks(slot.process);
        slot.previous_sample_ms = now_ms;
        slot.sample_count = 0;
        slot.sample_cursor = 0;
        slot.cpu_sent = false;
        slot.memory_sent = false;
        slot.media_sent = false;
    }

    fn rendererDesired(self: *const Host) bool {
        if (self.force_software) return false;
        for (&self.slots) |slot| {
            if (slot.used and slot.enabled and slot.wants_gpu and slot.state != .stopped and slot.state != .source_missing) return true;
        }
        return false;
    }

    fn superviseRenderer(self: *Host, now_ms: u64) void {
        if (self.renderer.process) |process| {
            if (c.WaitForSingleObject(process, 0) == c.WAIT_OBJECT_0) {
                _ = c.CloseHandle(process);
                self.renderer.process = null;
                self.renderer.pid = 0;
                self.thread_sample_ms = 0;
                self.renderer.crash_count += 1;
                const delays = [_]u64{ 1000, 5000, 30_000 };
                self.renderer.next_restart_ms = now_ms + delays[@min(self.renderer.crash_count - 1, delays.len - 1)];
            } else if (!self.rendererDesired()) {
                _ = c.TerminateProcess(process, 0);
                _ = c.WaitForSingleObject(process, 1000);
                _ = c.CloseHandle(process);
                self.renderer = .{};
                self.thread_sample_ms = 0;
            }
        }
        if (self.renderer.process == null and self.rendererDesired() and now_ms >= self.renderer.next_restart_ms) {
            self.ensureRenderer(now_ms) catch {
                self.renderer.next_restart_ms = now_ms + 1000;
            };
        }
    }

    fn ensureRenderer(self: *Host, now_ms: u64) !void {
        if (self.force_software or self.renderer.process != null or now_ms < self.renderer.next_restart_ms) return;
        const command = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{self.renderer_exe});
        defer self.allocator.free(command);
        const command_w_const = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, command);
        defer self.allocator.free(command_w_const);
        const command_w = try self.allocator.dupeZ(u16, command_w_const);
        defer self.allocator.free(command_w);
        const pipe_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, self.renderer_pipe_name);
        defer self.allocator.free(pipe_w);
        const log_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, self.renderer_log_path);
        defer self.allocator.free(log_w);
        if (c.SetEnvironmentVariableW(env_renderer_pipe, pipe_w.ptr) == 0) return error.SetEnvironmentFailed;
        if (c.SetEnvironmentVariableW(env_renderer_log, log_w.ptr) == 0) return error.SetEnvironmentFailed;
        defer {
            _ = c.SetEnvironmentVariableW(env_renderer_pipe, null);
            _ = c.SetEnvironmentVariableW(env_renderer_log, null);
        }
        var startup: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
        startup.cb = @sizeOf(c.STARTUPINFOW);
        var info: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);
        if (c.CreateProcessW(null, command_w.ptr, null, null, 0, c.CREATE_NO_WINDOW,
            null, null, &startup, &info) == 0) return error.CreateRendererFailed;
        _ = c.CloseHandle(info.hThread);
        self.renderer.process = info.hProcess;
        self.renderer.pid = info.dwProcessId;
        self.thread_sample_ms = 0;
        self.renderer.started_ms = now_ms;
        self.renderer.previous_process_ticks = processTicks(info.hProcess);
        self.renderer.previous_sample_ms = now_ms;
        self.renderer.sample_count = 0;
        self.renderer.sample_cursor = 0;
    }

    fn handleExit(self: *Host, slot: *Slot, now_ms: u64) void {
        var exit_code: c.DWORD = 1;
        _ = c.GetExitCodeProcess(slot.process, &exit_code);
        self.closeProcess(slot);
        if (!self.sourceExists(slot.source())) {
            slot.state = .source_missing;
            slot.next_restart_ms = 0;
            slot.setReason("registered source path does not exist", .{});
            return;
        }
        self.recordCrash(slot, now_ms, exit_code);
    }

    fn recordCrash(_: *Host, slot: *Slot, now_ms: u64, exit_code: ?u32) void {
        if (backoff.recordCrash(&slot.crash_times, &slot.crash_count, now_ms)) {
            slot.state = .stopped;
            slot.setReason("crashed after 3 restart attempts within 5 minutes{s}{?d}", .{ if (exit_code != null) ": exit code " else "", exit_code });
            return;
        }
        slot.state = .backoff;
        slot.next_restart_ms = now_ms + backoff.delayMs(slot.crash_count);
        slot.setReason("crashed; restart {d} in {d}s", .{ slot.crash_count, backoff.delayMs(slot.crash_count) / 1000 });
    }

    fn stopSlot(self: *Host, slot: *Slot, graceful: bool) void {
        if (slot.process) |process| {
            if (graceful) {
                closeWindowsForProcess(slot.pid);
                if (c.WaitForSingleObject(process, 1500) != c.WAIT_OBJECT_0) _ = c.TerminateProcess(process, 0);
            } else _ = c.TerminateProcess(process, 0);
            _ = c.WaitForSingleObject(process, 1000);
        }
        self.closeProcess(slot);
    }

    fn closeProcess(self: *Host, slot: *Slot) void {
        self.closePipe(slot);
        if (slot.process) |process| _ = c.CloseHandle(process);
        slot.process = null;
        slot.pid = 0;
        self.thread_sample_ms = 0;
        slot.previous_process_ticks = 0;
    }

    fn closePipe(_: *Host, slot: *Slot) void {
        if (slot.pipe == invalid_handle) return;
        _ = c.FlushFileBuffers(slot.pipe);
        _ = c.DisconnectNamedPipe(slot.pipe);
        _ = c.CloseHandle(slot.pipe);
        slot.pipe = invalid_handle;
    }

    fn sampleCosts(self: *Host, now_ms: u64) void {
        for (&self.slots) |*slot| {
            const process = slot.process orelse continue;
            var counters: c.PROCESS_MEMORY_COUNTERS_EX = std.mem.zeroes(c.PROCESS_MEMORY_COUNTERS_EX);
            counters.cb = @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX);
            if (c.GetProcessMemoryInfo(process, @ptrCast(&counters), @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX)) == 0) continue;
            const ticks = processTicks(process);
            const elapsed_ms = now_ms -| slot.previous_sample_ms;
            const tick_delta = ticks -| slot.previous_process_ticks;
            const cpu = if (elapsed_ms == 0) 0 else 100.0 * @as(f64, @floatFromInt(tick_delta)) / 10_000.0 / @as(f64, @floatFromInt(elapsed_ms));
            slot.private_samples[slot.sample_cursor] = counters.PrivateUsage;
            slot.cpu_samples[slot.sample_cursor] = @round(cpu * 10.0) / 10.0;
            slot.sample_cursor = (slot.sample_cursor + 1) % slot.private_samples.len;
            slot.sample_count = @min(slot.sample_count + 1, slot.private_samples.len);
            slot.previous_process_ticks = ticks;
            slot.previous_sample_ms = now_ms;
        }
        if (self.renderer.process) |process| {
            var counters: c.PROCESS_MEMORY_COUNTERS_EX = std.mem.zeroes(c.PROCESS_MEMORY_COUNTERS_EX);
            counters.cb = @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX);
            if (c.GetProcessMemoryInfo(process, @ptrCast(&counters), @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX)) != 0) {
                const ticks = processTicks(process);
                const elapsed_ms = now_ms -| self.renderer.previous_sample_ms;
                const tick_delta = ticks -| self.renderer.previous_process_ticks;
                const cpu = if (elapsed_ms == 0) 0 else 100.0 * @as(f64, @floatFromInt(tick_delta)) / 10_000.0 / @as(f64, @floatFromInt(elapsed_ms));
                self.renderer.private_samples[self.renderer.sample_cursor] = counters.PrivateUsage;
                self.renderer.cpu_samples[self.renderer.sample_cursor] = @round(cpu * 10.0) / 10.0;
                self.renderer.sample_cursor = (self.renderer.sample_cursor + 1) % self.renderer.private_samples.len;
                self.renderer.sample_count = @min(self.renderer.sample_count + 1, self.renderer.private_samples.len);
                self.renderer.previous_process_ticks = ticks;
                self.renderer.previous_sample_ms = now_ms;
            }
        }
    }

    fn sampleProviders(self: *Host) void {
        var any = false;
        for (&self.slots) |*slot| if (slot.process != null and (slot.wants_cpu or slot.wants_memory)) { any = true; break; };
        if (!any) return;
        const sample = self.sampler.sample() catch return orelse return;
        var cpu_buffer: [8192]u8 = undefined;
        const cpu = providers.formatCpu(sample.cpu, &cpu_buffer) catch return;
        var memory_buffer: [512]u8 = undefined;
        const memory = providers.formatMemory(sample.memory, &memory_buffer) catch return;
        const cpu_changed = !std.mem.eql(u8, cpu, self.previous_cpu[0..self.previous_cpu_len]);
        const memory_changed = !std.mem.eql(u8, memory, self.previous_memory[0..self.previous_memory_len]);
        for (&self.slots) |*slot| {
            if (slot.pipe == invalid_handle) continue;
            if (slot.wants_cpu and (!slot.cpu_sent or cpu_changed) and writePipe(slot.pipe, cpu)) slot.cpu_sent = true;
            if (slot.wants_memory and (!slot.memory_sent or memory_changed) and writePipe(slot.pipe, memory)) slot.memory_sent = true;
        }
        @memcpy(self.previous_cpu[0..cpu.len], cpu);
        self.previous_cpu_len = cpu.len;
        @memcpy(self.previous_memory[0..memory.len], memory);
        self.previous_memory_len = memory.len;
    }

    fn hasAudioSubscribers(self: *const Host) bool {
        for (&self.slots) |slot| if (slot.process != null and slot.wants_audio) return true;
        return false;
    }

    fn hasMediaSubscribers(self: *const Host) bool {
        for (&self.slots) |slot| if (slot.process != null and slot.wants_media) return true;
        return false;
    }

    fn sampleAudio(self: *Host, now_ms: u64) void {
        const active = self.hasAudioSubscribers();
        self.audio_provider.setActive(active, now_ms);
        if (!active) return;
        const frame = self.audio_provider.poll(now_ms) orelse return;
        var buffer: [512]u8 = undefined;
        const encoded = audio.formatFrame(frame, &buffer) catch return;
        var delivered = false;
        for (&self.slots) |*slot| {
            if (slot.pipe == invalid_handle or !slot.wants_audio) continue;
            if (writePipe(slot.pipe, encoded)) delivered = true;
        }
        if (delivered) self.audio_pipe_frames += 1;
    }

    fn sampleMedia(self: *Host, now_ms: u64) void {
        const active = self.hasMediaSubscribers();
        self.media_provider.setActive(active, now_ms);
        if (!active) return;
        const frame = self.media_provider.poll(now_ms) orelse return;
        var buffer: [2048]u8 = undefined;
        const encoded = media.formatFrame(&frame, &buffer) catch return;
        const changed = !std.mem.eql(u8, encoded, self.previous_media[0..self.previous_media_len]);
        var delivered = false;
        for (&self.slots) |*slot| {
            if (slot.pipe == invalid_handle or !slot.wants_media) continue;
            if ((!slot.media_sent or changed) and writePipe(slot.pipe, encoded)) {
                slot.media_sent = true;
                delivered = true;
            }
        }
        if (delivered) self.media_pipe_frames += 1;
        @memcpy(self.previous_media[0..encoded.len], encoded);
        self.previous_media_len = encoded.len;
    }

    fn writeStatus(self: *Host, now_ms: u64) void {
        if (self.thread_sample_ms == 0 or now_ms -| self.thread_sample_ms >= 30_000) {
            self.slot_threads = [_]u32{0} ** max_widgets;
            self.renderer_threads = 0;
            collectThreadCounts(self, &self.slot_threads, &self.renderer_threads);
            self.thread_sample_ms = now_ms;
        }
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{ .whitespace = .indent_2 } };
        json.beginObject() catch return;
        json.objectField("hostPid") catch return;
        json.write(c.GetCurrentProcessId()) catch return;
        json.objectField("providers") catch return;
        json.beginObject() catch return;
        json.objectField("audioCaptureActive") catch return;
        json.write(self.audio_provider.capture != null) catch return;
        json.objectField("audioSilent") catch return;
        json.write(self.audio_provider.silent) catch return;
        json.objectField("audioPipeFrames") catch return;
        json.write(self.audio_pipe_frames) catch return;
        json.objectField("mediaPipeFrames") catch return;
        json.write(self.media_pipe_frames) catch return;
        json.endObject() catch return;
        json.objectField("widgets") catch return;
        json.beginArray() catch return;
        if (self.renderer.process != null) {
            const average = self.renderer.averages();
            json.beginObject() catch return;
            json.objectField("name") catch return;
            json.write("renderer") catch return;
            json.objectField("pid") catch return;
            json.write(self.renderer.pid) catch return;
            json.objectField("privateMb") catch return;
            json.write(average.private_mb) catch return;
            json.objectField("cpuPercent") catch return;
            json.write(average.cpu) catch return;
            json.objectField("threads") catch return;
            json.write(self.renderer_threads) catch return;
            json.objectField("backend") catch return;
            json.write("gpu") catch return;
            json.objectField("uptimeSeconds") catch return;
            json.write((now_ms -| self.renderer.started_ms) / 1000) catch return;
            json.objectField("state") catch return;
            json.write("running") catch return;
            json.objectField("reason") catch return;
            json.write("") catch return;
            json.endObject() catch return;
        }
        for (&self.slots, 0..) |*slot, slot_index| {
            if (!slot.used) continue;
            const average = slot.averages();
            json.beginObject() catch return;
            json.objectField("name") catch return;
            json.write(slot.name()) catch return;
            json.objectField("pid") catch return;
            json.write(slot.pid) catch return;
            json.objectField("privateMb") catch return;
            json.write(average.private_mb) catch return;
            json.objectField("cpuPercent") catch return;
            json.write(average.cpu) catch return;
            json.objectField("threads") catch return;
            json.write(self.slot_threads[slot_index]) catch return;
            json.objectField("backend") catch return;
            if (slot.process != null and slot.backend_path_len > 0) {
                const backend = std.Io.Dir.cwd().readFileAlloc(self.io, slot.backendPath(), self.allocator, .limited(16)) catch null;
                if (backend) |value| {
                    json.write(value) catch { self.allocator.free(value); return; };
                    self.allocator.free(value);
                } else json.write("-") catch return;
            } else json.write("-") catch return;
            json.objectField("uptimeSeconds") catch return;
            json.write(if (slot.process != null) (now_ms -| slot.started_ms) / 1000 else 0) catch return;
            json.objectField("state") catch return;
            json.write(runStateLabel(slot.state)) catch return;
            json.objectField("reason") catch return;
            json.write(slot.reason()) catch return;
            json.endObject() catch return;
        }
        json.endArray() catch return;
        json.endObject() catch return;
        var cwd = std.Io.Dir.cwd();
        cwd.writeFile(self.io, .{ .sub_path = self.status_temp_path, .data = output.written() }) catch return;
        cwd.rename(self.status_temp_path, cwd, self.status_path, self.io) catch return;
    }

    fn ensureBundle(self: *Host, source: []const u8) !void {
        const source_path = try std.fs.path.join(self.allocator, &.{ source, "widget.tsx" });
        defer self.allocator.free(source_path);
        const bundle_path = try std.fs.path.join(self.allocator, &.{ source, "dist", "bundle.js" });
        defer self.allocator.free(bundle_path);
        const manifest_path = try std.fs.path.join(self.allocator, &.{ source, "dist", "widget.json" });
        defer self.allocator.free(manifest_path);
        const source_stat = try std.Io.Dir.cwd().statFile(self.io, source_path, .{});
        const bundle_stat = std.Io.Dir.cwd().statFile(self.io, bundle_path, .{}) catch null;
        const manifest_stat = std.Io.Dir.cwd().statFile(self.io, manifest_path, .{}) catch null;
        if (bundle_stat != null and manifest_stat != null and bundle_stat.?.mtime.nanoseconds >= source_stat.mtime.nanoseconds) return;
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "node", self.cli_script, "bundle", source },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .create_no_window = true,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.BundleFailed,
            else => return error.BundleFailed,
        }
    }

    fn artifactMtime(self: *Host, source: []const u8) i128 {
        const path = std.fs.path.join(self.allocator, &.{ source, "dist", "bundle.js" }) catch return 0;
        defer self.allocator.free(path);
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return 0;
        return stat.mtime.nanoseconds;
    }

    fn sourceExists(self: *Host, source: []const u8) bool {
        _ = std.Io.Dir.cwd().statFile(self.io, source, .{}) catch return false;
        return true;
    }
};

test "source-missing state has the status contract spelling" {
    try std.testing.expectEqualStrings("source missing", runStateLabel(.source_missing));
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--signal-down")) return signalEvent(shutdown_event_name);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--signal-reload")) return signalEvent(reload_event_name);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--probe")) {
        const handle = c.OpenMutexW(c.SYNCHRONIZE, 0, mutex_name);
        if (handle == null) return error.HostNotRunning;
        _ = c.CloseHandle(handle);
        return;
    }
    const mutex = c.CreateMutexW(null, 0, mutex_name) orelse return error.CreateMutexFailed;
    defer _ = c.CloseHandle(mutex);
    if (c.GetLastError() == c.ERROR_ALREADY_EXISTS) return;
    const shutdown_event = c.CreateEventW(null, 1, 0, shutdown_event_name) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(shutdown_event);
    const reload_event = c.CreateEventW(null, 0, 0, reload_event_name) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(reload_event);
    const local_app_data = init.environ_map.get("LOCALAPPDATA") orelse return error.MissingLocalAppData;
    const directory = try std.fs.path.join(allocator, &.{ local_app_data, "weaver" });
    defer allocator.free(directory);
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    const registry_path = try std.fs.path.join(allocator, &.{ directory, "registry.json" });
    defer allocator.free(registry_path);
    const status_path = try std.fs.path.join(allocator, &.{ directory, "status.json" });
    defer allocator.free(status_path);
    const status_temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{status_path});
    defer allocator.free(status_temp_path);
    const repo_root = try repositoryRoot(allocator);
    defer allocator.free(repo_root);
    const runtime_exe = try std.fs.path.join(allocator, &.{ repo_root, "runtime", "zig-out", "bin", "weaver-widget.exe" });
    defer allocator.free(runtime_exe);
    const renderer_exe = try std.fs.path.join(allocator, &.{ repo_root, "renderer", "zig-out", "bin", "weaver-renderer.exe" });
    defer allocator.free(renderer_exe);
    const renderer_pipe_name = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\weaver-renderer-{d}", .{c.GetCurrentProcessId()});
    defer allocator.free(renderer_pipe_name);
    const renderer_log_path = try std.fmt.allocPrint(allocator, "{s}.renderer.log", .{status_path});
    defer allocator.free(renderer_log_path);
    std.Io.Dir.cwd().deleteFile(init.io, renderer_log_path) catch {};
    const cli_script = try std.fs.path.join(allocator, &.{ repo_root, "cli", "dist", "index.js" });
    defer allocator.free(cli_script);
    var host: Host = .{
        .io = init.io,
        .allocator = allocator,
        .repo_root = repo_root,
        .registry_path = registry_path,
        .status_path = status_path,
        .status_temp_path = status_temp_path,
        .runtime_exe = runtime_exe,
        .renderer_exe = renderer_exe,
        .renderer_pipe_name = renderer_pipe_name,
        .renderer_log_path = renderer_log_path,
        .cli_script = cli_script,
        .force_software = if (init.environ_map.get("WEAVER_FORCE_SOFTWARE")) |value| std.mem.eql(u8, value, "1") else false,
    };
    defer host.audio_provider.deinit();
    defer host.media_provider.deinit();
    try host.loadRegistry();
    var next_provider_ms: u64 = 0;
    var next_cost_ms: u64 = 0;
    while (true) {
        const handles = [_]c.HANDLE{ shutdown_event, reload_event };
        const wait_ms: c.DWORD = if (host.hasAudioSubscribers()) 10 else 250;
        const wait = c.WaitForMultipleObjects(handles.len, &handles, 0, wait_ms);
        if (wait == c.WAIT_OBJECT_0) break;
        if (wait == c.WAIT_OBJECT_0 + 1) host.loadRegistry() catch {};
        const now = c.GetTickCount64();
        host.supervise(now);
        host.sampleAudio(now);
        host.sampleMedia(now);
        if (now >= next_provider_ms) {
            host.sampleProviders();
            next_provider_ms = now + 1000;
        }
        if (now >= next_cost_ms) {
            host.sampleCosts(now);
            host.writeStatus(now);
            next_cost_ms = now + 2000;
        }
    }
    for (&host.slots) |*slot| if (slot.process != null) host.stopSlot(slot, true);
    if (host.renderer.process) |process| {
        _ = c.TerminateProcess(process, 0);
        _ = c.WaitForSingleObject(process, 1000);
        _ = c.CloseHandle(process);
        host.renderer.process = null;
    }
    host.writeStatus(c.GetTickCount64());
}

fn signalEvent(name: [*:0]const u16) !void {
    const event = c.OpenEventW(c.EVENT_MODIFY_STATE, 0, name) orelse return error.HostNotRunning;
    defer _ = c.CloseHandle(event);
    if (c.SetEvent(event) == 0) return error.SignalFailed;
}

fn repositoryRoot(allocator: std.mem.Allocator) ![]u8 {
    var path_w: [32768]u16 = undefined;
    const length = c.GetModuleFileNameW(null, &path_w, path_w.len);
    if (length == 0 or length == path_w.len) return error.ExecutablePathFailed;
    const path = try std.unicode.utf16LeToUtf8Alloc(allocator, path_w[0..length]);
    defer allocator.free(path);
    const bin_dir = std.fs.path.dirname(path) orelse return error.ExecutablePathFailed;
    const zig_out = std.fs.path.dirname(bin_dir) orelse return error.ExecutablePathFailed;
    const host_dir = std.fs.path.dirname(zig_out) orelse return error.ExecutablePathFailed;
    const repo = std.fs.path.dirname(host_dir) orelse return error.ExecutablePathFailed;
    return allocator.dupe(u8, repo);
}

fn findSlot(slots: *[max_widgets]Slot, name: []const u8) ?usize {
    for (slots, 0..) |*slot, index| if (slot.used and std.mem.eql(u8, slot.name(), name)) return index;
    return null;
}

fn findFreeSlot(slots: *[max_widgets]Slot) ?usize {
    for (slots, 0..) |*slot, index| if (!slot.used) return index;
    return null;
}

fn processTicks(process: c.HANDLE) u64 {
    var created: c.FILETIME = undefined;
    var exited: c.FILETIME = undefined;
    var kernel: c.FILETIME = undefined;
    var user: c.FILETIME = undefined;
    if (c.GetProcessTimes(process, &created, &exited, &kernel, &user) == 0) return 0;
    return fileTime(kernel) + fileTime(user);
}

fn fileTime(value: c.FILETIME) u64 {
    return (@as(u64, value.dwHighDateTime) << 32) | value.dwLowDateTime;
}

fn collectThreadCounts(host: *const Host, slot_counts: *[max_widgets]u32, renderer_count: *u32) void {
    const snapshot = c.CreateToolhelp32Snapshot(c.TH32CS_SNAPTHREAD, 0);
    if (snapshot == invalid_handle) return;
    defer _ = c.CloseHandle(snapshot);
    var entry: c.THREADENTRY32 = std.mem.zeroes(c.THREADENTRY32);
    entry.dwSize = @sizeOf(c.THREADENTRY32);
    if (c.Thread32First(snapshot, &entry) == 0) return;
    while (true) {
        if (entry.th32OwnerProcessID == host.renderer.pid) renderer_count.* += 1;
        for (&host.slots, 0..) |slot, index| {
            if (slot.pid != 0 and entry.th32OwnerProcessID == slot.pid) slot_counts[index] += 1;
        }
        if (c.Thread32Next(snapshot, &entry) == 0) break;
    }
}

fn writePipe(pipe: c.HANDLE, bytes: []const u8) bool {
    var written: c.DWORD = 0;
    return c.WriteFile(pipe, bytes.ptr, @intCast(bytes.len), &written, null) != 0 and written == bytes.len;
}

fn connectPipe(pipe: c.HANDLE, process: c.HANDLE, timeout_ms: u64) bool {
    const deadline = c.GetTickCount64() + timeout_ms;
    while (true) {
        if (c.ConnectNamedPipe(pipe, null) != 0 or c.GetLastError() == c.ERROR_PIPE_CONNECTED) break;
        const pipe_error = c.GetLastError();
        if (pipe_error != c.ERROR_PIPE_LISTENING and pipe_error != c.ERROR_NO_DATA) return false;
        if (c.WaitForSingleObject(process, 0) == c.WAIT_OBJECT_0 or c.GetTickCount64() >= deadline) return false;
        c.Sleep(10);
    }
    var mode: c.DWORD = c.PIPE_READMODE_BYTE | c.PIPE_WAIT;
    return c.SetNamedPipeHandleState(pipe, &mode, null, null) != 0;
}

fn closeWindowsForProcess(pid: u32) void {
    const Callback = struct {
        fn call(window: c.HWND, process_id: c.LPARAM) callconv(.c) c.BOOL {
            var owner: c.DWORD = 0;
            _ = c.GetWindowThreadProcessId(window, &owner);
            if (owner == @as(u32, @intCast(process_id))) _ = c.PostMessageW(window, c.WM_CLOSE, 0, 0);
            return 1;
        }
    };
    _ = c.EnumWindows(Callback.call, @intCast(pid));
}

test {
    _ = audio;
    _ = registry;
    _ = backoff;
    _ = media;
    _ = providers;
}
