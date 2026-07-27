const builtin = @import("builtin");
const supervisor = @import("supervisor.zig");
const platform_host = switch (builtin.os.tag) {
    .windows => @import("windows_host.zig"),
    .macos => @import("macos_host.zig"),
    else => @compileError("weaverd supports only Windows and macOS"),
};

pub fn main(init: @import("std").process.Init) void {
    platform_host.main(init);
}

// Referencing the platform host is not enough to reach the tests in the files
// it imports: unreferenced decls are never analyzed, so those imports are never
// evaluated and their tests are silently dropped from the binary. Every host
// source file with tests must be listed here by hand.
test {
    _ = supervisor;
    _ = platform_host;
    _ = @import("art_cache.zig");
    _ = @import("audio.zig");
    _ = @import("backoff.zig");
    _ = @import("media.zig");
    _ = @import("media_commands.zig");
    _ = @import("provider_protocol.zig");
    _ = @import("registry.zig");
    if (builtin.os.tag == .macos) _ = @import("providers_macos.zig");
    if (builtin.os.tag == .windows) _ = @import("providers.zig");
}
