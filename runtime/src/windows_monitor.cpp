#include "windows_monitor.h"

#include <windows.h>

namespace {

UINT effectiveMonitorDpi(HMONITOR monitor) {
    using GetDpiForMonitorFn = HRESULT(WINAPI *)(HMONITOR, int, UINT *, UINT *);
    HMODULE shcore = LoadLibraryW(L"shcore.dll");
    const auto get_monitor_dpi = shcore
        ? reinterpret_cast<GetDpiForMonitorFn>(GetProcAddress(shcore,
              "GetDpiForMonitor"))
        : nullptr;
    UINT dpi_x = 0;
    UINT dpi_y = 0;
    if (get_monitor_dpi && monitor &&
        get_monitor_dpi(monitor, 0, &dpi_x, &dpi_y) == S_OK && dpi_y > 0) {
        FreeLibrary(shcore);
        return dpi_y;
    }
    if (shcore) FreeLibrary(shcore);

    using GetDpiForSystemFn = UINT(WINAPI *)();
    const auto get_system_dpi = reinterpret_cast<GetDpiForSystemFn>(
        GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForSystem"));
    if (get_system_dpi) {
        const UINT dpi = get_system_dpi();
        if (dpi > 0) return dpi;
    }
    HDC dc = GetDC(nullptr);
    if (dc) {
        const int dpi = GetDeviceCaps(dc, LOGPIXELSY);
        ReleaseDC(nullptr, dc);
        if (dpi > 0) return static_cast<UINT>(dpi);
    }
    return 96;
}

} // namespace

int weaver_primary_monitor_geometry(WeaverPrimaryMonitorGeometry *geometry) {
    if (!geometry) return 0;
    const POINT primary_origin = { 0, 0 };
    HMONITOR monitor = MonitorFromPoint(primary_origin, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO info = {};
    info.cbSize = sizeof(info);
    if (!monitor || !GetMonitorInfoW(monitor, &info)) return 0;
    geometry->work_left_px = info.rcWork.left;
    geometry->work_top_px = info.rcWork.top;
    geometry->work_right_px = info.rcWork.right;
    geometry->work_bottom_px = info.rcWork.bottom;
    geometry->effective_dpi = effectiveMonitorDpi(monitor);
    return geometry->effective_dpi > 0 ? 1 : 0;
}

int weaver_virtual_screen_bounds(WeaverVirtualScreenBounds *bounds) {
    if (!bounds) return 0;
    const int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (width <= 0 || height <= 0) return 0;
    bounds->left_px = left;
    bounds->top_px = top;
    bounds->right_px = left + width;
    bounds->bottom_px = top + height;
    return 1;
}
