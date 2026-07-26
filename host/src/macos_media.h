#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int weaver_macos_media_supported(void);
int weaver_macos_normalize_artwork(const uint8_t *input, size_t input_length,
                                   uint8_t **output, size_t *output_length,
                                   uint32_t *width, uint32_t *height);
void weaver_macos_free_artwork(uint8_t *bytes);

#ifdef __cplusplus
}
#endif
