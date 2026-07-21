#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct WeaverPrimaryMonitorGeometry {
    int32_t work_left_px;
    int32_t work_top_px;
    int32_t work_right_px;
    int32_t work_bottom_px;
    uint32_t effective_dpi;
};

int weaver_primary_monitor_geometry(struct WeaverPrimaryMonitorGeometry *geometry);

struct WeaverVirtualScreenBounds {
    int32_t left_px;
    int32_t top_px;
    int32_t right_px;
    int32_t bottom_px;
};

int weaver_virtual_screen_bounds(struct WeaverVirtualScreenBounds *bounds);

#ifdef __cplusplus
}
#endif
