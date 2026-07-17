const std = @import("std");
const windows = std.os.windows;

pub fn currentProcessId() u32 {
    return windows.GetCurrentProcessId();
}

pub fn monotonicMilliseconds() u64 {
    var counter: windows.LARGE_INTEGER = undefined;
    var frequency: windows.LARGE_INTEGER = undefined;
    if (!windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool()) return 0;
    if (!windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool()) return 0;
    if (frequency <= 0) return 0;
    return @intCast(@as(u128, @intCast(@max(counter, 0))) * std.time.ms_per_s / @as(u128, @intCast(frequency)));
}

pub fn wallClockMilliseconds() i64 {
    const epoch_ns: i96 = @as(i96, std.time.epoch.windows) * std.time.ns_per_s;
    const unix_ns = @as(i96, windows.ntdll.RtlGetSystemTimePrecise()) * 100 + epoch_ns;
    return @intCast(@divTrunc(unix_ns, std.time.ns_per_ms));
}

pub fn dataRoot(allocator: std.mem.Allocator, local_app_data: ?[]const u8, _: ?[]const u8) ![]u8 {
    const root = local_app_data orelse return error.MissingLocalAppData;
    return std.fs.path.join(allocator, &.{ root, "weaver" });
}

pub fn logsRoot(allocator: std.mem.Allocator, local_app_data: ?[]const u8, home: ?[]const u8) ![]u8 {
    const data = try dataRoot(allocator, local_app_data, home);
    defer allocator.free(data);
    return std.fs.path.join(allocator, &.{ data, "logs" });
}

pub fn providerEndpoint(local_endpoint: ?[]const u8, generic_endpoint: ?[]const u8) ?[]const u8 {
    return local_endpoint orelse generic_endpoint;
}
