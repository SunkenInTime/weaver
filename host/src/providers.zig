const std = @import("std");
const protocol = @import("provider_protocol.zig");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("winternl.h");
});

pub const max_cores = protocol.max_cores;
pub const Cpu = protocol.Cpu;
pub const Memory = protocol.Memory;
pub const Sample = protocol.Sample;
pub const formatCpu = protocol.formatCpu;
pub const formatMemory = protocol.formatMemory;

pub const Sampler = struct {
    previous: [max_cores]c.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION = undefined,
    previous_count: usize = 0,
    initialized: bool = false,
    sample_calls: u64 = 0,

    /// NtQuerySystemInformation is the smallest reliable per-core source on
    /// supported Windows releases. One host sample is rounded and fanned to
    /// every subscriber; widgets never instantiate PDH queries themselves.
    pub fn sample(self: *Sampler) !?Sample {
        self.sample_calls += 1;
        var current: [max_cores]c.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION = undefined;
        var returned: c.ULONG = 0;
        const status = c.NtQuerySystemInformation(
            c.SystemProcessorPerformanceInformation,
            &current,
            @sizeOf(@TypeOf(current)),
            &returned,
        );
        if (status < 0) return error.ProcessorSampleFailed;
        const count = @min(@as(usize, returned) / @sizeOf(c.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION), max_cores);
        var memory_status: c.MEMORYSTATUSEX = std.mem.zeroes(c.MEMORYSTATUSEX);
        memory_status.dwLength = @sizeOf(c.MEMORYSTATUSEX);
        if (c.GlobalMemoryStatusEx(&memory_status) == 0) return error.MemorySampleFailed;
        if (!self.initialized or count != self.previous_count) {
            @memcpy(self.previous[0..count], current[0..count]);
            self.previous_count = count;
            self.initialized = true;
            return null;
        }
        var cpu: Cpu = .{ .core_count = count };
        var aggregate_idle: u64 = 0;
        var aggregate_total: u64 = 0;
        for (current[0..count], self.previous[0..count], 0..) |now, before, index| {
            const idle = delta(now.IdleTime.QuadPart, before.IdleTime.QuadPart);
            const kernel = delta(now.KernelTime.QuadPart, before.KernelTime.QuadPart);
            const user = delta(now.UserTime.QuadPart, before.UserTime.QuadPart);
            const total = kernel + user;
            aggregate_idle += idle;
            aggregate_total += total;
            cpu.per_core[index] = protocol.roundTenth(if (total == 0) 0 else 100.0 * @as(f64, @floatFromInt(total -| idle)) / @as(f64, @floatFromInt(total)));
        }
        cpu.percent = protocol.roundTenth(if (aggregate_total == 0) 0 else 100.0 * @as(f64, @floatFromInt(aggregate_total -| aggregate_idle)) / @as(f64, @floatFromInt(aggregate_total)));
        @memcpy(self.previous[0..count], current[0..count]);
        const total_mb = memory_status.ullTotalPhys / (1024 * 1024);
        const used_mb = (memory_status.ullTotalPhys - memory_status.ullAvailPhys) / (1024 * 1024);
        return .{
            .cpu = cpu,
            .memory = .{
                .used_mb = used_mb,
                .total_mb = total_mb,
                .percent = protocol.roundTenth(@as(f64, @floatFromInt(used_mb)) * 100.0 / @as(f64, @floatFromInt(total_mb))),
            },
        };
    }
};

fn delta(now: c.LONGLONG, before: c.LONGLONG) u64 {
    return if (now > before) @intCast(now - before) else 0;
}

test {
    _ = protocol;
}
