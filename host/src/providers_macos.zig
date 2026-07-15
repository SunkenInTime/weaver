const std = @import("std");
const protocol = @import("provider_protocol.zig");

const c = @cImport({
    @cInclude("mach/mach.h");
    @cInclude("mach/mach_host.h");
    @cInclude("mach/processor_info.h");
    @cInclude("mach/vm_statistics.h");
    @cInclude("sys/sysctl.h");
});

pub const Sampler = struct {
    previous: [protocol.max_cores][c.CPU_STATE_MAX]u32 = @splat(@splat(0)),
    previous_count: usize = 0,
    initialized: bool = false,
    sample_calls: u64 = 0,

    /// `host_processor_info` is one public, host-owned per-core snapshot.
    /// `usedMb` preserves the SDK's existing meaning: total physical memory
    /// minus free and inactive (reclaimable) pages from `host_statistics64`.
    pub fn sample(self: *Sampler) !?protocol.Sample {
        self.sample_calls += 1;
        var processor_count: c.natural_t = 0;
        var processor_info: c.processor_info_array_t = null;
        var processor_info_count: c.mach_msg_type_number_t = 0;
        if (c.host_processor_info(
            c.mach_host_self(),
            c.PROCESSOR_CPU_LOAD_INFO,
            &processor_count,
            &processor_info,
            &processor_info_count,
        ) != c.KERN_SUCCESS) return error.ProcessorSampleFailed;
        defer _ = c.vm_deallocate(
            c.mach_task_self(),
            @intFromPtr(processor_info),
            @as(c.vm_size_t, processor_info_count) * @sizeOf(c.integer_t),
        );

        const count = @min(@as(usize, processor_count), protocol.max_cores);
        const loads: [*]const c.processor_cpu_load_info_data_t = @ptrCast(@alignCast(processor_info));
        const memory = try sampleMemory();
        if (!self.initialized or count != self.previous_count) {
            for (loads[0..count], 0..) |load, index| self.remember(index, load);
            self.previous_count = count;
            self.initialized = true;
            return null;
        }

        var cpu: protocol.Cpu = .{ .core_count = count };
        var aggregate_busy: u64 = 0;
        var aggregate_total: u64 = 0;
        for (loads[0..count], 0..) |load, index| {
            var busy: u64 = 0;
            var total: u64 = 0;
            for (0..c.CPU_STATE_MAX) |state| {
                const now: u32 = @intCast(load.cpu_ticks[state]);
                const ticks: u64 = now -% self.previous[index][state];
                total += ticks;
                if (state != c.CPU_STATE_IDLE) busy += ticks;
                self.previous[index][state] = now;
            }
            aggregate_busy += busy;
            aggregate_total += total;
            cpu.per_core[index] = protocol.roundTenth(percent(busy, total));
        }
        cpu.percent = protocol.roundTenth(percent(aggregate_busy, aggregate_total));
        return .{ .cpu = cpu, .memory = memory };
    }

    fn remember(self: *Sampler, index: usize, load: c.processor_cpu_load_info_data_t) void {
        for (0..c.CPU_STATE_MAX) |state| self.previous[index][state] = @intCast(load.cpu_ticks[state]);
    }
};

fn sampleMemory() !protocol.Memory {
    var total_bytes: u64 = 0;
    var total_size: usize = @sizeOf(@TypeOf(total_bytes));
    if (c.sysctlbyname("hw.memsize", &total_bytes, &total_size, null, 0) != 0 or total_bytes == 0) return error.MemorySampleFailed;
    var statistics: c.vm_statistics64_data_t = std.mem.zeroes(c.vm_statistics64_data_t);
    var statistics_count: c.mach_msg_type_number_t = c.HOST_VM_INFO64_COUNT;
    if (c.host_statistics64(
        c.mach_host_self(),
        c.HOST_VM_INFO64,
        @ptrCast(&statistics),
        &statistics_count,
    ) != c.KERN_SUCCESS) return error.MemorySampleFailed;
    var page_size: c.vm_size_t = 0;
    if (c.host_page_size(c.mach_host_self(), &page_size) != c.KERN_SUCCESS or page_size == 0) return error.MemorySampleFailed;
    const reclaimable_pages = @as(u64, statistics.free_count) + statistics.inactive_count;
    const reclaimable_bytes = @min(total_bytes, reclaimable_pages * @as(u64, page_size));
    const used_bytes = total_bytes - reclaimable_bytes;
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
