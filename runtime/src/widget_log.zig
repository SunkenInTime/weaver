const std = @import("std");
const platform = @import("platform/root.zig");

const rotate_bytes: u64 = 1024 * 1024;
var io: ?std.Io = null;
var path_buffer: [32768]u8 = undefined;
var path_len: usize = 0;
var old_path_buffer: [32768]u8 = undefined;
var old_path_len: usize = 0;
var mutex: std.atomic.Mutex = .unlocked;

pub fn init(runtime_io: std.Io, path: []const u8) !void {
    if (path.len + ".old".len > path_buffer.len) return error.LogPathTooLong;
    @memcpy(path_buffer[0..path.len], path);
    path_len = path.len;
    @memcpy(old_path_buffer[0..path.len], path);
    @memcpy(old_path_buffer[path.len .. path.len + ".old".len], ".old");
    old_path_len = path.len + ".old".len;
    io = runtime_io;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writeTimestamp(&writer) catch return;
    writer.print(" {s}", .{level.asText()}) catch return;
    if (scope != .default) writer.print("({t})", .{scope}) catch return;
    writer.writeAll(": ") catch return;
    writer.print(format, args) catch return;
    writer.writeByte('\n') catch return;
    writeLine(writer.buffered());
}

fn writeTimestamp(writer: *std.Io.Writer) !void {
    const milliseconds: u64 = @intCast(@max(0, platform.wallClockMilliseconds()));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = milliseconds / std.time.ms_per_s };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    try writer.print("[{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z]", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        milliseconds % std.time.ms_per_s,
    });
}

fn writeLine(line: []const u8) void {
    const runtime_io = io orelse return;
    if (path_len == 0) return;
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
    defer mutex.unlock();

    var cwd = std.Io.Dir.cwd();
    const path = path_buffer[0..path_len];
    const old_path = old_path_buffer[0..old_path_len];
    const size = if (cwd.statFile(runtime_io, path, .{})) |stat| stat.size else |_| 0;
    if (shouldRotate(size, line.len)) {
        cwd.deleteFile(runtime_io, old_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return,
        };
        cwd.rename(path, cwd, old_path, runtime_io) catch return;
    }
    var file = cwd.createFile(runtime_io, path, .{ .read = true, .truncate = false }) catch return;
    defer file.close(runtime_io);
    const stat = file.stat(runtime_io) catch return;
    file.writePositionalAll(runtime_io, line, stat.size) catch return;
}

fn shouldRotate(size: u64, incoming: usize) bool {
    return size > 0 and size + incoming > rotate_bytes;
}

test "rotation threshold is one MiB and never rotates an empty file" {
    try std.testing.expectEqual(@as(u64, 1_048_576), rotate_bytes);
    try std.testing.expect(!shouldRotate(0, rotate_bytes + 1));
    try std.testing.expect(!shouldRotate(rotate_bytes - 1, 1));
    try std.testing.expect(shouldRotate(rotate_bytes, 1));
}
