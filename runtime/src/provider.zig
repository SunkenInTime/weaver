const builtin = @import("builtin");

const implementation = switch (builtin.os.tag) {
    .windows => @import("provider_windows.zig"),
    .macos => @import("provider_macos.zig"),
    else => @compileError("Weaver providers support only Windows and macOS"),
};

pub const Client = implementation.Client;

test "provider client is inert only without an endpoint" {
    const std = @import("std");
    var client: Client = .{};
    try client.init(null);
    defer client.deinit();
    try std.testing.expect(!client.available);
    if (builtin.os.tag == .macos) {
        try std.testing.expectError(error.UnsupportedHostEndpoint, client.init("/tmp/weaver-host.sock"));
    }
}
