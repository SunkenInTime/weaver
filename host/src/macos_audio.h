#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WeaverAudioCapture WeaverAudioCapture;

enum {
    WEAVER_AUDIO_STARTING = 1,
    WEAVER_AUDIO_RUNNING = 2,
    WEAVER_AUDIO_PERMISSION_DENIED = 3,
    WEAVER_AUDIO_DEVICE_UNAVAILABLE = 4,
    WEAVER_AUDIO_CAPTURE_FAILED = 5,
};

WeaverAudioCapture *weaver_audio_create(void);
void weaver_audio_destroy(WeaverAudioCapture *capture);
int weaver_audio_poll(WeaverAudioCapture *capture, float *mono, size_t capacity, size_t *sample_count);
uint32_t weaver_audio_sample_rate(const WeaverAudioCapture *capture);
int weaver_audio_default_device_is_current(const WeaverAudioCapture *capture);
int weaver_audio_status(const WeaverAudioCapture *capture);
int32_t weaver_audio_error(const WeaverAudioCapture *capture);

#ifdef __cplusplus
}
#endif
