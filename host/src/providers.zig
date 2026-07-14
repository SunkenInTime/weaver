const std = @import("std");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("winternl.h");
});

pub const max_cores: usize = 256;

pub const Cpu = struct {
    percent: f64 = 0,
    per_core: [max_cores]f64 = [_]f64{0} ** max_cores,
    core_count: usize = 0,
};

pub const Memory = struct {
    used_mb: u64,
    total_mb: u64,
    percent: f64,
};

pub const Sample = struct { cpu: Cpu, memory: Memory };

pub const Sampler = struct {
    previous: [max_cores]c.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION = undefined,
    previous_count: usize = 0,
    initialized: bool = false,

    /// NtQuerySystemInformation is the smallest reliable per-core source on
    /// supported Windows releases. One host sample is rounded and fanned to
    /// every subscriber; widgets never instantiate PDH queries themselves.
    pub fn sample(self: *Sampler) !?Sample {
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
            cpu.per_core[index] = roundTenth(if (total == 0) 0 else 100.0 * @as(f64, @floatFromInt(total -| idle)) / @as(f64, @floatFromInt(total)));
        }
        cpu.percent = roundTenth(if (aggregate_total == 0) 0 else 100.0 * @as(f64, @floatFromInt(aggregate_total -| aggregate_idle)) / @as(f64, @floatFromInt(aggregate_total)));
        @memcpy(self.previous[0..count], current[0..count]);
        const total_mb = memory_status.ullTotalPhys / (1024 * 1024);
        const used_mb = (memory_status.ullTotalPhys - memory_status.ullAvailPhys) / (1024 * 1024);
        return .{
            .cpu = cpu,
            .memory = .{
                .used_mb = used_mb,
                .total_mb = total_mb,
                .percent = roundTenth(@as(f64, @floatFromInt(used_mb)) * 100.0 / @as(f64, @floatFromInt(total_mb))),
            },
        };
    }
};

pub fn formatCpu(cpu: Cpu, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"provider\":\"cpu\",\"value\":{{\"percent\":{d:.1},\"perCore\":[", .{cpu.percent});
    for (cpu.per_core[0..cpu.core_count], 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{d:.1}", .{value});
    }
    try writer.writeAll("]}}\n");
    return writer.buffered();
}

pub fn formatMemory(memory: Memory, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"provider\":\"memory\",\"value\":{{\"usedMb\":{d},\"totalMb\":{d},\"percent\":{d:.1}}}}}\n", .{
        memory.used_mb,
        memory.total_mb,
        memory.percent,
    });
    return writer.buffered();
}

fn delta(now: c.LONGLONG, before: c.LONGLONG) u64 {
    return if (now > before) @intCast(now - before) else 0;
}

fn roundTenth(value: f64) f64 {
    return @round(value * 10.0) / 10.0;
}

test "provider frames use the contract field names" {
    var output: [256]u8 = undefined;
    var cpu: Cpu = .{ .percent = 12.3, .core_count = 2 };
    cpu.per_core[0] = 10;
    cpu.per_core[1] = 14.5;
    try std.testing.expectEqualStrings(
        "{\"provider\":\"cpu\",\"value\":{\"percent\":12.3,\"perCore\":[10.0,14.5]}}\n",
        try formatCpu(cpu, &output),
    );
}
