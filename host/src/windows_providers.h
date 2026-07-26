#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WeaverAudioCapture WeaverAudioCapture;

WeaverAudioCapture *weaver_audio_create(void);
void weaver_audio_destroy(WeaverAudioCapture *capture);
int weaver_audio_poll(WeaverAudioCapture *capture, float *mono, size_t capacity, size_t *sample_count);
uint32_t weaver_audio_sample_rate(const WeaverAudioCapture *capture);
int weaver_audio_default_device_is_current(const WeaverAudioCapture *capture);

typedef struct WeaverMediaState {
    char title[512];
    char artist[512];
    char album[512];
    char source_app[257];
    int playing;
    int status;
    int64_t position_ms;
    int64_t duration_ms;
} WeaverMediaState;

#define WEAVER_MEDIA_STATUS_STOPPED 0
#define WEAVER_MEDIA_STATUS_PLAYING 1
#define WEAVER_MEDIA_STATUS_PAUSED 2

typedef struct WeaverMediaSession WeaverMediaSession;

typedef struct WeaverMediaArtwork {
    uint8_t *bytes;
    size_t length;
    int changed;
    int too_large;
    int refresh_failed;
    int session_changed;
    int unavailable;
} WeaverMediaArtwork;

WeaverMediaSession *weaver_media_create(void);
void weaver_media_destroy(WeaverMediaSession *session);
int weaver_media_poll(WeaverMediaSession *session, WeaverMediaState *state, WeaverMediaArtwork *artwork);
void weaver_media_artwork_release(WeaverMediaArtwork *artwork);
void weaver_media_select_source_app(const char *raw_id, const char *resolved_name, char output[257]);
int weaver_media_test_dirty_coalescing(void);
int weaver_media_test_refresh_retry(void);
int weaver_media_test_refresh_failure_bound(void);

#ifdef __cplusplus
}
#endif
