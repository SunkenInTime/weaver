const std = @import("std");
const native_sdk = @import("native_sdk");

const win = @cImport({
    @cInclude("windows.h");
});

pub const Manifest = struct {
    name: []const u8,
    size: [2]f32,
    anchor: struct {
        corner: []const u8,
        offset: [2]f32,
    },
    layer: []const u8,
    transparent: bool,
};

pub const Loaded = struct {
    manifest: Manifest,
    bundle: []const u8,
};

/// Load the two-file widget contract into the process-lifetime arena. M0 is
/// intentionally strict: unknown JSON fields and unsupported placement fail
/// at launch instead of quietly changing the desktop behavior.
pub fn load(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !Loaded {
    const manifest_path = try std.fs.path.join(allocator, &.{ directory, "widget.json" });
    const bundle_path = try std.fs.path.join(allocator, &.{ directory, "bundle.js" });
    const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(64 * 1024));
    const bundle = try std.Io.Dir.cwd().readFileAlloc(io, bundle_path, allocator, .limited(1024 * 1024));
    const parsed = try std.json.parseFromSliceLeaky(Manifest, allocator, manifest_bytes, .{ .ignore_unknown_fields = false });
    if (parsed.size[0] <= 0 or parsed.size[1] <= 0) return error.InvalidWidgetSize;
    if (!std.mem.eql(u8, parsed.anchor.corner, "top-right")) return error.UnsupportedAnchor;
    if (!std.mem.eql(u8, parsed.layer, "desktop")) return error.UnsupportedLayer;
    if (!parsed.transparent) return error.UnsupportedOpaqueWidget;
    return .{ .manifest = parsed, .bundle = bundle };
}

pub fn desktopFrame(value: Manifest) native_sdk.geometry.RectF {
    var work_area: win.RECT = undefined;
    if (win.SystemParametersInfoW(win.SPI_GETWORKAREA, 0, &work_area, 0) == 0) {
        work_area = .{
            .left = 0,
            .top = 0,
            .right = win.GetSystemMetrics(win.SM_CXSCREEN),
            .bottom = win.GetSystemMetrics(win.SM_CYSCREEN),
        };
    }
    const x = @as(f32, @floatFromInt(work_area.right)) - value.size[0] - value.anchor.offset[0];
    const y = @as(f32, @floatFromInt(work_area.top)) + value.anchor.offset[1];
    return native_sdk.geometry.RectF.init(x, y, value.size[0], value.size[1]);
}

test "clock manifest shape parses" {
    const source =
        \\{"name":"Clock","size":[240,110],"anchor":{"corner":"top-right","offset":[24,24]},"layer":"desktop","transparent":true}
    ;
    const parsed = try std.json.parseFromSlice(Manifest, std.testing.allocator, source, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f32, 240), parsed.value.size[0]);
}
