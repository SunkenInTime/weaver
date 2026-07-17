const posix = @import("std").posix;

pub fn currentProcessId() u32 {
    return @intCast(@max(0, posix.system.getpid()));
}
