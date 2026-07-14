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

#ifdef __cplusplus
}
#endif
