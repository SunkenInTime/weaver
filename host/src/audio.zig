const std = @import("std");

const native = @cImport({
    @cInclude("windows_providers.h");
});

pub const fft_size: usize = 2048;
pub const band_count: usize = 32;
pub const silence_floor: f64 = 0.0005;
pub const silence_hold_ms: u64 = 2000;

pub const Frame = struct {
    rms: f64 = 0,
    bands: [band_count]f64 = [_]f64{0} ** band_count,
};

/// The analyzer owns one rolling 2048-sample window. WASAPI conversion and
/// mono mixdown stop at the C boundary; windowing, FFT, log-band projection,
/// and AGC remain deterministic Zig with no DSP dependency.
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

        var energy: [band_count]f64 = [_]f64{0} ** band_count;
        var bins: [band_count]usize = [_]usize{0} ** band_count;
        const nyquist_bin = fft_size / 2;
        for (1..nyquist_bin) |bin| {
            const frequency = @as(f64, @floatFromInt(bin)) * @as(f64, @floatFromInt(sample_rate)) / @as(f64, @floatFromInt(fft_size));
            if (frequency < 20 or frequency > 16_000) continue;
            const normalized = @log(frequency / 20.0) / @log(16_000.0 / 20.0);
            const band = @min(band_count - 1, @as(usize, @intFromFloat(@floor(normalized * band_count))));
            energy[band] += self.real[bin] * self.real[bin] + self.imaginary[bin] * self.imaginary[bin];
            bins[band] += 1;
        }
        for (0..band_count) |band| {
            const amplitude = if (bins[band] == 0) 0 else @sqrt(energy[band] / @as(f64, @floatFromInt(bins[band]))) / (@as(f64, @floatFromInt(fft_size)) * 0.25);
            const db = 20.0 * @log10(@max(amplitude, 0.000_000_001));
            if (db >= self.peak_db[band]) self.peak_db[band] = db else self.peak_db[band] = @max(-60, self.peak_db[band] - 0.05);
            const floor_db = self.peak_db[band] - 36.0;
            frame.bands[band] = roundThousandth(std.math.clamp((db - floor_db) / 36.0, 0, 1));
        }
        frame.rms = roundThousandth(frame.rms);
        return frame;
    }
};

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

    pub fn deinit(self: *Provider) void {
        self.close();
    }

    pub fn setActive(self: *Provider, active: bool, now_ms: u64) void {
        if (!active) {
            self.close();
            self.analyzer = .{};
            self.silent = true;
            self.zero_sent = false;
            return;
        }
        if (self.capture == null and now_ms >= self.next_open_ms) self.open(now_ms);
    }

    /// Polling is non-blocking. The host calls it from its wait loop only
    /// while an audio subscriber exists, so no COM endpoint, FFT, or JSON
    /// serialization survives after the last subscriber exits.
    pub fn poll(self: *Provider, now_ms: u64) ?Frame {
        if (self.capture == null) {
            if (now_ms >= self.next_open_ms) self.open(now_ms);
            return null;
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
            self.reopen(now_ms);
            return null;
        }
        self.analyzer.push(input[0..count]);
        if (now_ms < self.next_frame_ms) return null;
        // Advance the deadline rather than rebasing it on a late wake. The
        // Windows wait is commonly quantized above 10 ms; a fixed accumulator
        // preserves a 30 Hz long-run rate without emitting catch-up bursts.
        self.next_frame_ms = advanceDeadline(self.next_frame_ms, now_ms);
        const rms = self.analyzer.rms();
        if (rms < silence_floor) {
            if (self.silence_started_ms == 0) self.silence_started_ms = now_ms;
            if (now_ms -| self.silence_started_ms < silence_hold_ms) {
                // Zero frames during the hold give subscribers time to decay
                // visibly. At two seconds one final zero is sent and the
                // provider becomes completely quiet until signal returns.
                self.frame_count += 1;
                return .{};
            }
            self.silent = true;
            if (self.zero_sent) return null;
            self.zero_sent = true;
            self.frame_count += 1;
            return .{};
        }
        self.silence_started_ms = 0;
        self.silent = false;
        self.zero_sent = false;
        self.frame_count += 1;
        return self.analyzer.spectrum(self.sample_rate);
    }

    fn open(self: *Provider, now_ms: u64) void {
        self.capture = native.weaver_audio_create();
        if (self.capture) |capture| {
            self.sample_rate = native.weaver_audio_sample_rate(capture);
            self.next_device_check_ms = now_ms + 1000;
            self.next_frame_ms = now_ms;
            return;
        }
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
