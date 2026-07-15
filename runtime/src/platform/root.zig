const builtin = @import("builtin");

const implementation = switch (builtin.os.tag) {
    .windows => @import("windows.zig"),
    .macos => @import("macos.zig"),
    else => @compileError("Weaver platform services support only Windows and macOS"),
};

pub const currentProcessId = implementation.currentProcessId;
pub const monotonicMilliseconds = implementation.monotonicMilliseconds;
pub const wallClockMilliseconds = implementation.wallClockMilliseconds;
pub const dataRoot = implementation.dataRoot;
pub const logsRoot = implementation.logsRoot;
pub const providerEndpoint = implementation.providerEndpoint;

test "platform identity and clocks are available" {
    const std = @import("std");
    try std.testing.expect(currentProcessId() > 0);
    try std.testing.expect(monotonicMilliseconds() > 0);
    try std.testing.expect(wallClockMilliseconds() > 0);
}

test "platform roots use native conventions" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    const data = try dataRoot(allocator, "C:\\Users\\test\\AppData\\Local", "/Users/test");
    defer allocator.free(data);
    const logs = try logsRoot(allocator, "C:\\Users\\test\\AppData\\Local", "/Users/test");
    defer allocator.free(logs);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("C:\\Users\\test\\AppData\\Local\\weaver", data);
        try std.testing.expectEqualStrings("C:\\Users\\test\\AppData\\Local\\weaver\\logs", logs);
    } else {
        try std.testing.expectEqualStrings("/Users/test/Library/Application Support/Weaver", data);
        try std.testing.expectEqualStrings("/Users/test/Library/Logs/Weaver", logs);
    }
}

test "an explicit provider endpoint is never silently discarded" {
    const std = @import("std");
    try std.testing.expectEqualStrings("native", providerEndpoint("native", null).?);
    try std.testing.expectEqualStrings("generic", providerEndpoint(null, "generic").?);
    try std.testing.expect(providerEndpoint(null, null) == null);
}
