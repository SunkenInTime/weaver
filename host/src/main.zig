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

test {
    _ = supervisor;
    _ = platform_host;
}
