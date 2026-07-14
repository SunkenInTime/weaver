const std = @import("std");
const native_sdk = @import("native_sdk");

const win = @cImport({
    @cInclude("windows.h");
});

pub const Manifest = struct {
    name: []const u8,
    size: [2]f32,
    anchor: ?struct {
        monitor: []const u8 = "primary",
        corner: []const u8,
        offset: [2]f32 = .{ 24, 24 },
    } = null,
    layer: []const u8 = "desktop",
    clickThrough: bool = false,
    transparent: bool = true,
    origins: []const []const u8 = &.{},
    subscribe: []const []const u8 = &.{},
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
    if (parsed.anchor) |anchor| {
        if (!std.mem.eql(u8, anchor.monitor, "primary")) return error.UnsupportedMonitor;
        if (!std.mem.eql(u8, anchor.corner, "top-left") and !std.mem.eql(u8, anchor.corner, "top-right") and !std.mem.eql(u8, anchor.corner, "bottom-left") and !std.mem.eql(u8, anchor.corner, "bottom-right")) return error.UnsupportedAnchor;
    }
    if (!std.mem.eql(u8, parsed.layer, "desktop") and !std.mem.eql(u8, parsed.layer, "normal") and !std.mem.eql(u8, parsed.layer, "topmost")) return error.UnsupportedLayer;
    if (!parsed.transparent) return error.UnsupportedOpaqueWidget;
    for (parsed.origins) |origin| {
        if (origin.len == 0 or std.mem.indexOf(u8, origin, "://") != null or std.mem.indexOfAny(u8, origin, "/?#@") != null) return error.InvalidOrigin;
    }
    for (parsed.subscribe) |provider| {
        if (!std.mem.eql(u8, provider, "time") and !std.mem.eql(u8, provider, "cpu") and !std.mem.eql(u8, provider, "memory") and !std.mem.eql(u8, provider, "audio") and !std.mem.eql(u8, provider, "media")) return error.InvalidProvider;
    }
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
    const anchor = value.anchor orelse return native_sdk.geometry.RectF.init(
        @as(f32, @floatFromInt(work_area.right)) - value.size[0] - 24,
        @as(f32, @floatFromInt(work_area.top)) + 24,
        value.size[0],
        value.size[1],
    );
    const on_right = std.mem.endsWith(u8, anchor.corner, "right");
    const on_bottom = std.mem.startsWith(u8, anchor.corner, "bottom");
    const x = if (on_right)
        @as(f32, @floatFromInt(work_area.right)) - value.size[0] - anchor.offset[0]
    else
        @as(f32, @floatFromInt(work_area.left)) + anchor.offset[0];
    const y = if (on_bottom)
        @as(f32, @floatFromInt(work_area.bottom)) - value.size[1] - anchor.offset[1]
    else
        @as(f32, @floatFromInt(work_area.top)) + anchor.offset[1];
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
