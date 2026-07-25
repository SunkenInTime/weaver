const builtin = @import("builtin");
const media_protocol = @import("media_protocol.zig");

const implementation = switch (builtin.os.tag) {
    .windows => @import("provider_windows.zig"),
    .macos => @import("provider_macos.zig"),
    else => @compileError("Weaver providers support only Windows and macOS"),
};

pub const Client = implementation.Client;
pub const max_line_bytes = media_protocol.max_media_frame_bytes;

test "provider client is inert only without an endpoint" {
    const std = @import("std");
    var client: Client = .{};
    try client.init(std.testing.io, null);
    defer client.deinit();
    try std.testing.expect(!client.available);
}
