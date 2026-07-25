const std = @import("std");

pub const max_text_bytes: usize = 512;
pub const max_source_app_bytes: usize = 256;
pub const max_art_path_bytes: usize = 259;
pub const max_json_escape_bytes: usize = 6;

const max_media_frame_fixed =
    "{\"provider\":\"media\",\"value\":{\"title\":\"\",\"artist\":\"\",\"album\":\"\",\"playing\":false,\"status\":\"stopped\",\"sourceApp\":\"\",\"artPath\":\"\",\"positionMs\":18446744073709551615,\"durationMs\":18446744073709551615}}\n";

/// Must match host/src/media.zig. It is the complete newline-terminated v2
/// media-frame bound, including the optional PR 02 artPath field.
pub const max_media_frame_bytes: usize = max_media_frame_fixed.len +
    max_json_escape_bytes * (3 * max_text_bytes + max_source_app_bytes + max_art_path_bytes);

test "runtime media line bound matches the frozen worst-case formula" {
    try std.testing.expectEqual(@as(usize, 12_502), max_media_frame_bytes);
    try std.testing.expect(max_media_frame_bytes > 8192);
}
