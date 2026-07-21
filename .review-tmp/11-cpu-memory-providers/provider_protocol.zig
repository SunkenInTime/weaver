const std = @import("std");

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

pub fn roundTenth(value: f64) f64 {
    return @round(value * 10.0) / 10.0;
}

pub fn deliveryNeeded(wanted: bool, sent: bool, serialized_changed: bool) bool {
    return wanted and (!sent or serialized_changed);
}

test "provider frames use the exact public field names" {
    var output: [256]u8 = undefined;
    var cpu: Cpu = .{ .percent = 12.3, .core_count = 2 };
    cpu.per_core[0] = 10;
    cpu.per_core[1] = 14.5;
    try std.testing.expectEqualStrings(
        "{\"provider\":\"cpu\",\"value\":{\"percent\":12.3,\"perCore\":[10.0,14.5]}}\n",
        try formatCpu(cpu, &output),
    );
    try std.testing.expectEqualStrings(
        "{\"provider\":\"memory\",\"value\":{\"usedMb\":4096,\"totalMb\":8192,\"percent\":50.0}}\n",
        try formatMemory(.{ .used_mb = 4096, .total_mb = 8192, .percent = 50 }, &output),
    );
    try std.testing.expect(deliveryNeeded(true, false, false));
    try std.testing.expect(deliveryNeeded(true, true, true));
    try std.testing.expect(!deliveryNeeded(true, true, false));
    try std.testing.expect(!deliveryNeeded(false, false, true));
}
