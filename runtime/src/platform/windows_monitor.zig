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
