const windows = @import("std").os.windows;

pub fn currentProcessId() u32 {
    return windows.GetCurrentProcessId();
}
