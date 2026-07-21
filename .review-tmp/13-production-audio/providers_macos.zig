const std = @import("std");
const protocol = @import("provider_protocol.zig");

const c = @cImport({ @cInclude("macos_system.h"); });

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
