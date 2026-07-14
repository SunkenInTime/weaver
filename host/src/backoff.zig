const std = @import("std");

pub const crash_window_ms: u64 = 5 * 60 * 1000;
pub const restart_limit: usize = 3;
pub const history_capacity: usize = restart_limit + 1;

pub fn delayMs(crash_count: usize) u64 {
    return switch (crash_count) {
        0, 1 => 1_000,
        2 => 5_000,
        else => 30_000,
    };
}

pub fn recordCrash(times: *[history_capacity]u64, count: *usize, now_ms: u64) bool {
    var kept: usize = 0;
    for (times[0..count.*]) |timestamp| {
        if (now_ms -| timestamp < crash_window_ms) {
            times[kept] = timestamp;
            kept += 1;
        }
    }
    if (kept < times.len) {
        times[kept] = now_ms;
        kept += 1;
    }
    count.* = kept;
    return kept > restart_limit;
}

test "backoff uses one five and thirty second steps" {
    try std.testing.expectEqual(@as(u64, 1_000), delayMs(1));
    try std.testing.expectEqual(@as(u64, 5_000), delayMs(2));
    try std.testing.expectEqual(@as(u64, 30_000), delayMs(3));
}

test "three restart strikes inside five minutes stop after the final retry" {
    var times = [_]u64{0} ** history_capacity;
    var count: usize = 0;
    try std.testing.expect(!recordCrash(&times, &count, 10_000));
    try std.testing.expect(!recordCrash(&times, &count, 20_000));
    try std.testing.expect(!recordCrash(&times, &count, 30_000));
    try std.testing.expect(recordCrash(&times, &count, 40_000));
    times = [_]u64{0} ** history_capacity;
    count = 0;
    _ = recordCrash(&times, &count, 1);
    try std.testing.expect(!recordCrash(&times, &count, crash_window_ms + 2));
    try std.testing.expectEqual(@as(usize, 1), count);
}
