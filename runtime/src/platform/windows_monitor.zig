const win = @cImport({
    @cInclude("windows_monitor.h");
});

pub const Geometry = struct {
    work_left_px: i32,
    work_top_px: i32,
    work_right_px: i32,
    work_bottom_px: i32,
    effective_dpi: u32,
};

pub fn primary() ?Geometry {
    var native: win.WeaverPrimaryMonitorGeometry = undefined;
    if (win.weaver_primary_monitor_geometry(&native) == 0) return null;
    return .{
        .work_left_px = native.work_left_px,
        .work_top_px = native.work_top_px,
        .work_right_px = native.work_right_px,
        .work_bottom_px = native.work_bottom_px,
        .effective_dpi = native.effective_dpi,
    };
}

pub const VirtualBounds = struct {
    left_px: i32,
    top_px: i32,
    right_px: i32,
    bottom_px: i32,
};

/// The bounding box of every attached display in physical virtual-desktop
/// pixels — the space a persisted widget position must still intersect
/// after monitors come and go.
pub fn virtualScreen() ?VirtualBounds {
    var native: win.WeaverVirtualScreenBounds = undefined;
    if (win.weaver_virtual_screen_bounds(&native) == 0) return null;
    return .{
        .left_px = native.left_px,
        .top_px = native.top_px,
        .right_px = native.right_px,
        .bottom_px = native.bottom_px,
    };
}
