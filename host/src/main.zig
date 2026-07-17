const supervisor = @import("supervisor.zig");
const windows_host = @import("windows_host.zig");

pub fn main(init: @import("std").process.Init) void {
    windows_host.main(init);
}

test {
    _ = supervisor;
    _ = windows_host;
}
