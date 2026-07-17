const builtin = @import("builtin");

const implementation = switch (builtin.os.tag) {
    .windows => @import("windows.zig"),
    .macos => @import("macos.zig"),
    else => @compileError("Weaver platform services support only Windows and macOS"),
};

pub const currentProcessId = implementation.currentProcessId;

test "platform process identity is available" {
    try @import("std").testing.expect(currentProcessId() > 0);
}
