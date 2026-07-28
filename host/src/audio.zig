const std = @import("std");
const builtin = @import("builtin");

const native = if (builtin.os.tag == .macos)
    @cImport({ @cInclude("macos_audio.h"); })
else
    @cImport({ @cInclude("windows_providers.h"); });

pub const fft_size: usize = 2048;
pub const band_count: usize = 32;
pub const silence_floor: f64 = 0.0005;
/// Hysteresis gate: once the silence hold is armed (or silence has
/// latched), rms must clear this higher floor to count as signal again.
/// With a single threshold, device noise hovering at the floor re-armed
/// the two-second hold on every crossing, so `silent` stayed false for
/// minutes with nothing audibly playing (the published rms rounds to
/// 0.000 the whole time). Real playback sits orders of magnitude above
/// this; only the noise band between the two floors changes behavior.
pub const silence_resume_floor: f64 = 0.002;
pub const silence_hold_ms: u64 = 2000;

pub const Frame = struct {
    rms: f64 = 0,
    bands: [band_count]f64 = [_]f64{0} ** band_count,
};

pub const Availability = enum {
    idle,
    authorization_required,
    starting,
    live,
    permission_denied,
    permission_revoked,
    device_unavailable,
    capture_failed,

    pub fn label(self: Availability) []const u8 {
        return switch (self) {
            .idle => "idle",
            .authorization_required => "authorization-required",
            .starting => "starting",
            .live => "live",
            .permission_denied => "permission-denied",
            .permission_revoked => "permission-revoked",
            .device_unavailable => "device-unavailable",
            .capture_failed => "capture-failed",
        };
    }
};

/// The analyzer owns one rolling 2048-sample window. Platform capture and mono
/// mixdown stop at the C boundary; windowing, FFT, log-band projection, and
/// AGC remain deterministic Zig with no DSP dependency.
pub const Analyzer = struct {
    samples: [fft_size]f64 = [_]f64{0} ** fft_size,
    cursor: usize = 0,
    count: usize = 0,
    real: [fft_size]f64 = undefined,
    imaginary: [fft_size]f64 = undefined,
    peak_db: [band_count]f64 = [_]f64{-60} ** band_count,

    pub fn push(self: *Analyzer, input: []const f32) void {
        for (input) |sample| {
            self.samples[self.cursor] = @floatCast(sample);
            self.cursor = (self.cursor + 1) % fft_size;
            self.count = @min(self.count + 1, fft_size);
        }
    }

    pub fn rms(self: *const Analyzer) f64 {
        if (self.count == 0) return 0;
        var sum: f64 = 0;
        for (self.samples[0..self.count]) |sample| sum += sample * sample;
        return @sqrt(sum / @as(f64, @floatFromInt(self.count)));
    }

    pub fn spectrum(self: *Analyzer, sample_rate: u32) Frame {
        var frame: Frame = .{ .rms = std.math.clamp(self.rms(), 0, 1) };
        if (self.count < fft_size or sample_rate == 0) return frame;
        for (0..fft_size) |index| {
            const source = (self.cursor + index) % fft_size;
            const phase = 2.0 * std.math.pi * @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(fft_size - 1));
            const hann = 0.5 - 0.5 * @cos(phase);
            self.real[index] = self.samples[source] * hann;
            self.imaginary[index] = 0;
        }
        fft(&self.real, &self.imaginary);

        const bin_hz = @as(f64, @floatFromInt(sample_rate)) / @as(f64, @floatFromInt(fft_size));
        for (0..band_count) |band| {
            const mean_energy = self.bandMeanEnergy(bandEdgeHz(band), bandEdgeHz(band + 1), bin_hz);
            const amplitude = @sqrt(mean_energy) / (@as(f64, @floatFromInt(fft_size)) * 0.25);
            const db = 20.0 * @log10(@max(amplitude, 0.000_000_001));
            if (db >= self.peak_db[band]) self.peak_db[band] = db else self.peak_db[band] = @max(-60, self.peak_db[band] - 0.05);
            const floor_db = self.peak_db[band] - 36.0;
            frame.bands[band] = roundThousandth(std.math.clamp((db - floor_db) / 36.0, 0, 1));
        }
        frame.rms = roundThousandth(frame.rms);
        return frame;
    }

    fn binEnergy(self: *const Analyzer, bin: usize) f64 {
        return self.real[bin] * self.real[bin] + self.imaginary[bin] * self.imaginary[bin];
    }

    /// Mean bin energy inside one band. At the low end a log band is narrower
    /// than the FFT bin spacing, so no bin center falls inside it; that band
    /// samples the spectrum at its own center frequency instead of reporting
    /// zero. A band entirely below bin 1 samples bin 1, the closest the FFT can
    /// resolve. Bands above the highest resolvable bin report an honest zero.
    fn bandMeanEnergy(self: *const Analyzer, low_hz: f64, high_hz: f64, bin_hz: f64) f64 {
        // These annotations are load-bearing: `@min` against a comptime-known
        // bound narrows its result to the smallest type that fits, so an
        // unannotated `last` becomes a u10 and `last + 1` overflows on the
        // top bin.
        const last_bin: usize = fft_size / 2 - 1;
        const last_bin_hz = @as(f64, @floatFromInt(last_bin)) * bin_hz;
        // Nothing above the highest resolvable bin exists in the signal.
        if (low_hz >= last_bin_hz) return 0;

        const first: usize = @max(1, ceilBin(low_hz / bin_hz));
        const last: usize = @min(last_bin, floorBin(high_hz / bin_hz));
        if (first <= last) {
            var sum: f64 = 0;
            for (first..last + 1) |bin| sum += self.binEnergy(bin);
            return sum / @as(f64, @floatFromInt(last - first + 1));
        }

        // Geometric center keeps the sample point centered on a log axis.
        const center = std.math.clamp(
            @sqrt(low_hz * high_hz) / bin_hz,
            1.0,
            @as(f64, @floatFromInt(last_bin)),
        );
        const lower_f = @floor(center);
        const lower: usize = @intFromFloat(lower_f);
        const upper: usize = @min(lower + 1, last_bin);
        const blend = center - lower_f;
        return self.binEnergy(lower) * (1.0 - blend) + self.binEnergy(upper) * blend;
    }
};

pub const band_low_hz: f64 = 20.0;
pub const band_high_hz: f64 = 16_000.0;

/// Lower frequency of band `edge`; `bandEdgeHz(band_count)` is the top edge.
pub fn bandEdgeHz(edge: usize) f64 {
    const decades = @log(band_high_hz / band_low_hz);
    const fraction = @as(f64, @floatFromInt(edge)) / @as(f64, @floatFromInt(band_count));
    return band_low_hz * @exp(decades * fraction);
}

fn ceilBin(value: f64) usize {
    if (value <= 0) return 0;
    return @intFromFloat(@ceil(value));
}

fn floorBin(value: f64) usize {
    if (value <= 0) return 0;
    return @intFromFloat(@floor(value));
}

pub const Provider = struct {
    capture: ?*native.WeaverAudioCapture = null,
    analyzer: Analyzer = .{},
    sample_rate: u32 = 0,
    next_open_ms: u64 = 0,
    next_device_check_ms: u64 = 0,
    next_frame_ms: u64 = 0,
    silence_started_ms: u64 = 0,
    silent: bool = true,
    zero_sent: bool = false,
    frame_count: u64 = 0,
    capture_starts: u64 = 0,
    authorized: bool = true,
    was_live: bool = false,
    availability: Availability = .idle,
    last_error: i32 = 0,

    pub fn deinit(self: *Provider) void {
        self.close();
    }

    pub fn setAuthorized(self: *Provider, authorized: bool) void {
        if (self.authorized == authorized) return;
        self.authorized = authorized;
        self.close();
        self.next_open_ms = 0;
        self.was_live = false;
        self.availability = if (authorized) .idle else .authorization_required;
        self.last_error = 0;
    }

    pub fn setActive(self: *Provider, active: bool, now_ms: u64) void {
        if (!active) {
            self.close();
            self.analyzer = .{};
            self.silent = true;
            self.zero_sent = false;
            self.was_live = false;
            self.availability = .idle;
            return;
        }
        if (!self.authorized) {
            self.availability = .authorization_required;
            return;
        }
        if (self.next_open_ms == std.math.maxInt(u64)) {
            self.availability = if (self.was_live) .permission_revoked else .permission_denied;
            return;
        }
        if (self.capture == null and now_ms >= self.next_open_ms) self.open(now_ms);
    }

    /// Polling is non-blocking. The host calls it from its wait loop only
    /// while an audio subscriber exists, so no COM endpoint, FFT, or JSON
    /// serialization survives after the last subscriber exits.
    pub fn poll(self: *Provider, now_ms: u64) ?Frame {
        if (!self.authorized or self.next_open_ms == std.math.maxInt(u64)) return null;
        if (self.capture == null) {
            if (now_ms >= self.next_open_ms) self.open(now_ms);
            return null;
        }
        if (builtin.os.tag == .macos) {
            switch (native.weaver_audio_status(self.capture.?)) {
                native.WEAVER_AUDIO_STARTING => {
                    self.availability = .starting;
                    return null;
                },
                native.WEAVER_AUDIO_RUNNING => {
                    self.availability = .live;
                    self.was_live = true;
                    if (self.sample_rate == 0) self.sample_rate = native.weaver_audio_sample_rate(self.capture.?);
                },
                native.WEAVER_AUDIO_PERMISSION_DENIED => {
                    self.last_error = native.weaver_audio_error(self.capture.?);
                    self.availability = if (self.was_live) .permission_revoked else .permission_denied;
                    self.close();
                    self.next_open_ms = std.math.maxInt(u64);
                    return self.finalFailureFrame();
                },
                native.WEAVER_AUDIO_DEVICE_UNAVAILABLE => {
                    self.last_error = native.weaver_audio_error(self.capture.?);
                    self.availability = .device_unavailable;
                    self.reopen(now_ms);
                    return self.finalFailureFrame();
                },
                else => {
                    self.last_error = native.weaver_audio_error(self.capture.?);
                    self.availability = .capture_failed;
                    self.reopen(now_ms);
                    return self.finalFailureFrame();
                },
            }
        }
        if (now_ms >= self.next_device_check_ms) {
            self.next_device_check_ms = now_ms + 1000;
            if (native.weaver_audio_default_device_is_current(self.capture) == 0) {
                self.reopen(now_ms);
                return null;
            }
        }
        var input: [8192]f32 = undefined;
        var count: usize = 0;
        if (native.weaver_audio_poll(self.capture, &input, input.len, &count) < 0) {
            if (builtin.os.tag == .macos) {
                self.last_error = native.weaver_audio_error(self.capture.?);
                switch (native.weaver_audio_status(self.capture.?)) {
                    native.WEAVER_AUDIO_PERMISSION_DENIED => {
                        self.availability = if (self.was_live) .permission_revoked else .permission_denied;
                        self.close();
                        self.next_open_ms = std.math.maxInt(u64);
                        return self.finalFailureFrame();
                    },
                    native.WEAVER_AUDIO_DEVICE_UNAVAILABLE => self.availability = .device_unavailable,
                    else => self.availability = .capture_failed,
                }
            }
            self.reopen(now_ms);
            return self.finalFailureFrame();
        }
        self.analyzer.push(input[0..count]);
        if (now_ms < self.next_frame_ms) return null;
        // Advance the deadline rather than rebasing it on a late wake. The
        // Windows wait is commonly quantized above 10 ms; a fixed accumulator
        // preserves a 30 Hz long-run rate without emitting catch-up bursts.
        self.next_frame_ms = advanceDeadline(self.next_frame_ms, now_ms);
        const rms = self.analyzer.rms();
        switch (self.silenceAction(rms, now_ms)) {
            .decay => {
                // Zero frames during the hold give subscribers time to decay
                // visibly. At two seconds one final zero is sent and the
                // provider becomes completely quiet until signal returns.
                self.frame_count += 1;
                return .{};
            },
            .final_zero => {
                self.frame_count += 1;
                return .{};
            },
            .suppress => return null,
            .active => {},
        }
        self.frame_count += 1;
        return self.analyzer.spectrum(self.sample_rate);
    }

    fn open(self: *Provider, now_ms: u64) void {
        self.capture = native.weaver_audio_create();
        if (self.capture) |capture| {
            self.sample_rate = native.weaver_audio_sample_rate(capture);
            self.next_device_check_ms = now_ms + 1000;
            self.next_frame_ms = now_ms;
            self.capture_starts += 1;
            self.availability = if (builtin.os.tag == .macos) .starting else .live;
            if (builtin.os.tag != .macos) self.was_live = true;
            return;
        }
        self.availability = .capture_failed;
        self.next_open_ms = now_ms + 1000;
    }

    fn close(self: *Provider) void {
        if (self.capture) |capture| native.weaver_audio_destroy(capture);
        self.capture = null;
        self.sample_rate = 0;
    }

    fn reopen(self: *Provider, now_ms: u64) void {
        self.close();
        self.next_open_ms = now_ms + 250;
        self.analyzer = .{};
    }

    const SilenceAction = enum { active, decay, final_zero, suppress };

    fn silenceAction(self: *Provider, rms: f64, now_ms: u64) SilenceAction {
        const gate: f64 = if (self.silence_started_ms == 0 and !self.silent) silence_floor else silence_resume_floor;
        if (rms >= gate) {
            self.silence_started_ms = 0;
            self.silent = false;
            self.zero_sent = false;
            return .active;
        }
        if (self.silence_started_ms == 0) self.silence_started_ms = now_ms;
        if (now_ms -| self.silence_started_ms < silence_hold_ms) return .decay;
        self.silent = true;
        if (self.zero_sent) return .suppress;
        self.zero_sent = true;
        return .final_zero;
    }

    fn finalFailureFrame(self: *Provider) ?Frame {
        self.silent = true;
        if (!self.was_live or self.zero_sent) return null;
        self.zero_sent = true;
        self.frame_count += 1;
        return .{};
    }
};

pub fn formatFrame(frame: Frame, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"provider\":\"audio\",\"value\":{{\"rms\":{d:.3},\"bands\":[", .{frame.rms});
    for (frame.bands, 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{d:.3}", .{value});
    }
    try writer.writeAll("]}}\n");
    return writer.buffered();
}

fn fft(real: *[fft_size]f64, imaginary: *[fft_size]f64) void {
    var j: usize = 0;
    for (1..fft_size) |index| {
        var bit = fft_size >> 1;
        while ((j & bit) != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (index < j) {
            std.mem.swap(f64, &real[index], &real[j]);
            std.mem.swap(f64, &imaginary[index], &imaginary[j]);
        }
    }
    var length: usize = 2;
    while (length <= fft_size) : (length <<= 1) {
        const angle = -2.0 * std.math.pi / @as(f64, @floatFromInt(length));
        const step_real = @cos(angle);
        const step_imaginary = @sin(angle);
        var start: usize = 0;
        while (start < fft_size) : (start += length) {
            var weight_real: f64 = 1;
            var weight_imaginary: f64 = 0;
            for (0..length / 2) |offset| {
                const even = start + offset;
                const odd = even + length / 2;
                const odd_real = real[odd] * weight_real - imaginary[odd] * weight_imaginary;
                const odd_imaginary = real[odd] * weight_imaginary + imaginary[odd] * weight_real;
                real[odd] = real[even] - odd_real;
                imaginary[odd] = imaginary[even] - odd_imaginary;
                real[even] += odd_real;
                imaginary[even] += odd_imaginary;
                const next_real = weight_real * step_real - weight_imaginary * step_imaginary;
                weight_imaginary = weight_real * step_imaginary + weight_imaginary * step_real;
                weight_real = next_real;
            }
        }
    }
}

fn roundThousandth(value: f64) f64 {
    return @round(value * 1000.0) / 1000.0;
}

fn advanceDeadline(deadline_ms: u64, now_ms: u64) u64 {
    var next = if (deadline_ms == 0) now_ms else deadline_ms;
    while (next <= now_ms) next += 33;
    return next;
}

test "radix-2 analyzer places a one-kilohertz tone in its logarithmic band" {
    var analyzer: Analyzer = .{};
    var samples: [fft_size]f32 = undefined;
    for (&samples, 0..) |*sample, index| {
        sample.* = @floatCast(0.4 * @sin(2.0 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(index)) / 48_000.0));
    }
    analyzer.push(&samples);
    const frame = analyzer.spectrum(48_000);
    const maximum = std.mem.indexOfMax(f64, &frame.bands);
    try std.testing.expect(maximum >= 18 and maximum <= 20);
    try std.testing.expect(frame.bands[maximum] > 0.8);
}

fn pushNoise(analyzer: *Analyzer) void {
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const random = prng.random();
    var samples: [fft_size]f32 = undefined;
    for (&samples) |*sample| sample.* = @floatCast(random.float(f64) * 2.0 - 1.0);
    analyzer.push(&samples);
}

test "no log band is structurally dead at any supported sample rate" {
    // Regression: iterating bins and dropping empty bands pinned bands 1, 2, 3
    // and 5 to zero at 48 kHz (1, 2, 4 and 7 at 44.1 kHz), because a log band
    // below ~100 Hz is narrower than the 23.4 Hz bin spacing. Broadband input
    // must light every band whose range the FFT can measure.
    for ([_]u32{ 44_100, 48_000, 96_000 }) |rate| {
        var analyzer: Analyzer = .{};
        pushNoise(&analyzer);
        const frame = analyzer.spectrum(rate);
        for (frame.bands, 0..) |value, band| {
            std.testing.expect(value > 0) catch |err| {
                std.debug.print("rate {d} band {d} is dead\n", .{ rate, band });
                return err;
            };
        }
    }
}

test "bands above the measurable range report an honest zero" {
    // A 16 kHz tap resolves nothing above its 8 kHz Nyquist, so those bands
    // must stay zero rather than repeat the highest measurable bin.
    var analyzer: Analyzer = .{};
    pushNoise(&analyzer);
    const frame = analyzer.spectrum(16_000);
    const last_measurable_hz = @as(f64, @floatFromInt(fft_size / 2 - 1)) * 16_000.0 / @as(f64, @floatFromInt(fft_size));
    var saw_live = false;
    for (frame.bands, 0..) |value, band| {
        if (bandEdgeHz(band) >= last_measurable_hz) {
            try std.testing.expectEqual(@as(f64, 0), value);
        } else {
            try std.testing.expect(value > 0);
            saw_live = true;
        }
    }
    try std.testing.expect(saw_live);
}

test "low sample rates keep every band value in range" {
    // Below ~41 kHz, bin 1 sits under the 20 Hz band floor, and above the tap's
    // Nyquist the top bands have no bins at all. Neither edge may produce an
    // out-of-range value or an out-of-bounds bin index.
    for ([_]u32{ 8_000, 16_000, 32_000 }) |rate| {
        var analyzer: Analyzer = .{};
        pushNoise(&analyzer);
        const frame = analyzer.spectrum(rate);
        for (frame.bands) |value| {
            try std.testing.expect(value >= 0 and value <= 1);
        }
    }
}

test "band edges span the documented twenty hertz to sixteen kilohertz range" {
    try std.testing.expectApproxEqAbs(band_low_hz, bandEdgeHz(0), 0.000_001);
    try std.testing.expectApproxEqAbs(band_high_hz, bandEdgeHz(band_count), 0.001);
    for (1..band_count + 1) |edge| {
        try std.testing.expect(bandEdgeHz(edge) > bandEdgeHz(edge - 1));
    }
}

test "audio provider frame is one JSON line with 32 bands" {
    var output: [512]u8 = undefined;
    var frame: Frame = .{ .rms = 0.125 };
    frame.bands[31] = 1;
    const encoded = try formatFrame(frame, &output);
    try std.testing.expect(std.mem.startsWith(u8, encoded, "{\"provider\":\"audio\",\"value\":{\"rms\":0.125,\"bands\":["));
    try std.testing.expect(std.mem.endsWith(u8, encoded, "1.000]}}\n"));
}

test "audio deadline does not accumulate late Windows waits" {
    var deadline = advanceDeadline(0, 1000);
    try std.testing.expectEqual(@as(u64, 1033), deadline);
    deadline = advanceDeadline(deadline, 1047);
    try std.testing.expectEqual(@as(u64, 1066), deadline);
    deadline = advanceDeadline(deadline, 1094);
    try std.testing.expectEqual(@as(u64, 1099), deadline);
}

test "audio silence decays once, parks, and resumes on signal" {
    var provider: Provider = .{};
    try std.testing.expectEqual(Provider.SilenceAction.active, provider.silenceAction(0.2, 100));
    try std.testing.expectEqual(Provider.SilenceAction.decay, provider.silenceAction(0, 200));
    try std.testing.expectEqual(Provider.SilenceAction.decay, provider.silenceAction(0, 2199));
    try std.testing.expectEqual(Provider.SilenceAction.final_zero, provider.silenceAction(0, 2200));
    try std.testing.expectEqual(Provider.SilenceAction.suppress, provider.silenceAction(0, 2300));
    try std.testing.expectEqual(Provider.SilenceAction.active, provider.silenceAction(0.1, 2400));
    try std.testing.expect(!provider.silent);
    try std.testing.expect(!provider.zero_sent);
}

test "noise at the silence floor cannot re-arm the hold or unlatch silence" {
    var provider: Provider = .{};
    try std.testing.expectEqual(Provider.SilenceAction.active, provider.silenceAction(0.2, 100));
    // Noise-floor flapping between the two gates during the hold keeps
    // the hold running instead of resetting it on every crossing.
    try std.testing.expectEqual(Provider.SilenceAction.decay, provider.silenceAction(0.0004, 200));
    try std.testing.expectEqual(Provider.SilenceAction.decay, provider.silenceAction(0.0006, 300));
    try std.testing.expectEqual(Provider.SilenceAction.decay, provider.silenceAction(0.0004, 2199));
    try std.testing.expectEqual(Provider.SilenceAction.final_zero, provider.silenceAction(0.0006, 2200));
    try std.testing.expect(provider.silent);
    // Latched silence ignores the noise band and resumes on real signal.
    try std.testing.expectEqual(Provider.SilenceAction.suppress, provider.silenceAction(0.0019, 2300));
    try std.testing.expect(provider.silent);
    try std.testing.expectEqual(Provider.SilenceAction.active, provider.silenceAction(0.002, 2400));
    try std.testing.expect(!provider.silent);
}

test "live capture failure emits one final zero and then parks" {
    var provider: Provider = .{ .was_live = true, .silent = false };
    try std.testing.expect(provider.finalFailureFrame() != null);
    try std.testing.expect(provider.silent);
    try std.testing.expect(provider.zero_sent);
    try std.testing.expectEqual(@as(u64, 1), provider.frame_count);
    try std.testing.expect(provider.finalFailureFrame() == null);
    try std.testing.expectEqual(@as(u64, 1), provider.frame_count);
}
