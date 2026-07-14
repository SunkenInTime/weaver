const std = @import("std");

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

const rotate_bytes: u64 = 1024 * 1024;
var path_buffer: [32768]u16 = undefined;
var path_len: usize = 0;
var old_path_buffer: [32768]u16 = undefined;
var old_path_len: usize = 0;
var mutex: std.atomic.Mutex = .unlocked;

pub fn init(path: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(wide);
    if (wide.len + 5 >= path_buffer.len) return error.LogPathTooLong;
    @memcpy(path_buffer[0..wide.len], wide);
    path_buffer[wide.len] = 0;
    path_len = wide.len;
    @memcpy(old_path_buffer[0..wide.len], wide);
    @memcpy(old_path_buffer[wide.len .. wide.len + 4], std.unicode.utf8ToUtf16LeStringLiteral(".old"));
    old_path_len = wide.len + 4;
    old_path_buffer[old_path_len] = 0;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var local: win.SYSTEMTIME = undefined;
    win.GetLocalTime(&local);
    writer.print("[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] {s}", .{
        local.wYear, local.wMonth, local.wDay, local.wHour, local.wMinute, local.wSecond, local.wMilliseconds, level.asText(),
    }) catch return;
    if (scope != .default) writer.print("({t})", .{scope}) catch return;
    writer.writeAll(": ") catch return;
    writer.print(format, args) catch return;
    writer.writeByte('\n') catch return;
    writeLine(writer.buffered());
}

fn writeLine(line: []const u8) void {
    if (path_len == 0) return;
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
    defer mutex.unlock();

    var data: win.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    const exists = win.GetFileAttributesExW(@ptrCast(&path_buffer), win.GetFileExInfoStandard, &data) != 0;
    const size = if (exists) (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow else 0;
    if (size > 0 and size + line.len > rotate_bytes) {
        _ = win.DeleteFileW(@ptrCast(&old_path_buffer));
        _ = win.MoveFileExW(@ptrCast(&path_buffer), @ptrCast(&old_path_buffer), win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_WRITE_THROUGH);
    }
    const file = win.CreateFileW(@ptrCast(&path_buffer), win.FILE_APPEND_DATA, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, null, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win.INVALID_HANDLE_VALUE) return;
    defer _ = win.CloseHandle(file);
    var written: win.DWORD = 0;
    _ = win.WriteFile(file, line.ptr, @intCast(line.len), &written, null);
}

test "rotation threshold is one MiB" {
    try std.testing.expectEqual(@as(u64, 1_048_576), rotate_bytes);
}
