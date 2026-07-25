#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define WINRT_LEAN_AND_MEAN

#include "windows_providers.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <windows.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/base.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <new>
#include <string>

struct WeaverAudioCapture {
    IMMDeviceEnumerator *enumerator = nullptr;
    IMMDevice *device = nullptr;
    IAudioClient *client = nullptr;
    IAudioCaptureClient *capture = nullptr;
    WAVEFORMATEX *format = nullptr;
    LPWSTR device_id = nullptr;
    bool com_initialized = false;

    ~WeaverAudioCapture() {
        if (client) client->Stop();
        if (capture) capture->Release();
        if (client) client->Release();
        if (device) device->Release();
        if (enumerator) enumerator->Release();
        if (format) CoTaskMemFree(format);
        if (device_id) CoTaskMemFree(device_id);
        if (com_initialized) CoUninitialize();
    }
};

static bool is_float_format(const WAVEFORMATEX *format) {
    if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
    if (format->wFormatTag != WAVE_FORMAT_EXTENSIBLE || format->cbSize < 22) return false;
    const auto *extended = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(format);
    return IsEqualGUID(extended->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) != FALSE;
}

static bool is_pcm_format(const WAVEFORMATEX *format) {
    if (format->wFormatTag == WAVE_FORMAT_PCM) return true;
    if (format->wFormatTag != WAVE_FORMAT_EXTENSIBLE || format->cbSize < 22) return false;
    const auto *extended = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(format);
    return IsEqualGUID(extended->SubFormat, KSDATAFORMAT_SUBTYPE_PCM) != FALSE;
}

static float pcm_sample(const BYTE *frame, UINT32 channel, const WAVEFORMATEX *format) {
    const UINT32 bytes = format->wBitsPerSample / 8;
    const BYTE *sample = frame + channel * bytes;
    if (is_float_format(format) && format->wBitsPerSample == 32) {
        float value = 0;
        std::memcpy(&value, sample, sizeof(value));
        return std::isfinite(value) ? std::clamp(value, -1.0f, 1.0f) : 0.0f;
    }
    if (!is_pcm_format(format)) return 0.0f;
    if (format->wBitsPerSample == 16) {
        int16_t value = 0;
        std::memcpy(&value, sample, sizeof(value));
        return static_cast<float>(value) / 32768.0f;
    }
    if (format->wBitsPerSample == 24) {
        int32_t value = static_cast<int32_t>(sample[0]) |
            (static_cast<int32_t>(sample[1]) << 8) |
            (static_cast<int32_t>(sample[2]) << 16);
        if (value & 0x00800000) value |= static_cast<int32_t>(0xff000000);
        return static_cast<float>(value) / 8388608.0f;
    }
    if (format->wBitsPerSample == 32) {
        int32_t value = 0;
        std::memcpy(&value, sample, sizeof(value));
        return static_cast<float>(value) / 2147483648.0f;
    }
    return 0.0f;
}

extern "C" WeaverAudioCapture *weaver_audio_create(void) {
    auto state = std::make_unique<WeaverAudioCapture>();
    const HRESULT apartment = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(apartment) && apartment != RPC_E_CHANGED_MODE) return nullptr;
    state->com_initialized = apartment != RPC_E_CHANGED_MODE;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
            __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(&state->enumerator)))) return nullptr;
    if (FAILED(state->enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &state->device))) return nullptr;
    if (FAILED(state->device->GetId(&state->device_id))) return nullptr;
    if (FAILED(state->device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
            reinterpret_cast<void **>(&state->client)))) return nullptr;
    if (FAILED(state->client->GetMixFormat(&state->format))) return nullptr;
    if (!is_float_format(state->format) && !is_pcm_format(state->format)) return nullptr;
    if (FAILED(state->client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
            0, 0, state->format, nullptr))) return nullptr;
    if (FAILED(state->client->GetService(__uuidof(IAudioCaptureClient),
            reinterpret_cast<void **>(&state->capture)))) return nullptr;
    if (FAILED(state->client->Start())) return nullptr;
    return state.release();
}

extern "C" void weaver_audio_destroy(WeaverAudioCapture *capture) { delete capture; }

extern "C" uint32_t weaver_audio_sample_rate(const WeaverAudioCapture *capture) {
    return capture && capture->format ? capture->format->nSamplesPerSec : 0;
}

extern "C" int weaver_audio_default_device_is_current(const WeaverAudioCapture *capture) {
    if (!capture || !capture->enumerator || !capture->device_id) return 0;
    IMMDevice *current = nullptr;
    LPWSTR current_id = nullptr;
    const HRESULT endpoint = capture->enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &current);
    if (SUCCEEDED(endpoint)) current->GetId(&current_id);
    const bool same = current_id && std::wcscmp(current_id, capture->device_id) == 0;
    if (current_id) CoTaskMemFree(current_id);
    if (current) current->Release();
    return same ? 1 : 0;
}

extern "C" int weaver_audio_poll(WeaverAudioCapture *state, float *mono, size_t capacity, size_t *sample_count) {
    if (!state || !mono || !sample_count) return -1;
    *sample_count = 0;
    UINT32 packet = 0;
    HRESULT result = state->capture->GetNextPacketSize(&packet);
    if (FAILED(result)) return -2;
    while (packet > 0 && *sample_count < capacity) {
        BYTE *data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        result = state->capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (FAILED(result)) return -2;
        const UINT32 channels = state->format->nChannels;
        const UINT32 stride = state->format->nBlockAlign;
        const size_t available = std::min<size_t>(frames, capacity - *sample_count);
        for (size_t frame_index = 0; frame_index < available; ++frame_index) {
            float mixed = 0.0f;
            if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) == 0) {
                const BYTE *frame = data + frame_index * stride;
                for (UINT32 channel = 0; channel < channels; ++channel) mixed += pcm_sample(frame, channel, state->format);
                mixed /= static_cast<float>(std::max<UINT32>(1, channels));
            }
            mono[(*sample_count)++] = mixed;
        }
        state->capture->ReleaseBuffer(frames);
        result = state->capture->GetNextPacketSize(&packet);
        if (FAILED(result)) return -2;
    }
    return 0;
}

constexpr size_t max_artwork_bytes = 1024 * 1024;

struct WeaverMediaDirtyFlags {
    std::atomic<bool> session{true};
    std::atomic<bool> properties{true};

    void mark_session() {
        session.store(true, std::memory_order_release);
    }

    void mark_properties() {
        properties.store(true, std::memory_order_release);
    }

    bool take_session() {
        return session.exchange(false, std::memory_order_acq_rel);
    }

    bool take_properties() {
        return properties.exchange(false, std::memory_order_acq_rel);
    }
};

struct WeaverMediaSession {
    winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionManager manager{nullptr};
    winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSession current{nullptr};
    winrt::event_token manager_token{};
    winrt::event_token properties_token{};
    bool manager_subscribed = false;
    bool properties_subscribed = false;
    std::atomic<bool> shutting_down{false};
    WeaverMediaDirtyFlags dirty;
    std::string title;
    std::string artist;
    std::string album;
    std::string source_app;
    bool refresh_failed = false;
    bool apartment_initialized = false;

    ~WeaverMediaSession() {
        shutting_down.store(true, std::memory_order_release);
        try {
            if (properties_subscribed && current) current.MediaPropertiesChanged(properties_token);
        } catch (...) {
        }
        try {
            if (manager_subscribed && manager) manager.CurrentSessionChanged(manager_token);
        } catch (...) {
        }
        properties_subscribed = false;
        manager_subscribed = false;
        current = nullptr;
        manager = nullptr;
        if (apartment_initialized) winrt::uninit_apartment();
    }
};

template <size_t Capacity>
static void copy_text(char (&destination)[Capacity], const std::string &source) {
    const size_t length = std::min(source.size(), sizeof(destination) - 1);
    std::memcpy(destination, source.data(), length);
    destination[length] = '\0';
}

template <size_t Capacity>
static void copy_text(char (&destination)[Capacity], const winrt::hstring &source) {
    copy_text(destination, winrt::to_string(source));
}

static std::string select_source_app(const std::string &raw_id, const std::string &resolved_name) {
    return resolved_name.empty() ? raw_id : resolved_name;
}

static std::string source_app_name(const winrt::hstring &source_id) {
    const std::string raw_id = winrt::to_string(source_id);
    if (raw_id.empty()) return {};
    try {
        const auto app_info = winrt::Windows::ApplicationModel::AppInfo::GetFromAppUserModelId(source_id);
        if (!app_info || !app_info.Package()) return raw_id;
        return select_source_app(raw_id, winrt::to_string(app_info.DisplayInfo().DisplayName()));
    } catch (...) {
        return raw_id;
    }
}

static void clear_cached_properties(WeaverMediaSession *state) {
    state->title.clear();
    state->artist.clear();
    state->album.clear();
    state->source_app.clear();
}

static void rebind_current_session(WeaverMediaSession *state) {
    if (state->properties_subscribed && state->current) {
        state->current.MediaPropertiesChanged(state->properties_token);
    }
    state->properties_subscribed = false;
    state->current = nullptr;
    clear_cached_properties(state);
    state->current = state->manager.GetCurrentSession();
    if (state->current) {
        state->source_app = source_app_name(state->current.SourceAppUserModelId());
        state->properties_token = state->current.MediaPropertiesChanged(
            [state](const auto &, const auto &) {
                if (!state->shutting_down.load(std::memory_order_acquire)) state->dirty.mark_properties();
            });
        state->properties_subscribed = true;
    }
    state->dirty.mark_properties();
}

static bool read_thumbnail(
    const winrt::Windows::Storage::Streams::IRandomAccessStreamReference &reference,
    WeaverMediaArtwork *artwork) {
    artwork->changed = 1;
    if (!reference) return true;
    try {
        const auto stream = reference.OpenReadAsync().get();
        const uint64_t size = stream.Size();
        if (size > max_artwork_bytes) {
            artwork->too_large = 1;
            return true;
        }
        if (size == 0) return true;
        const auto input = stream.GetInputStreamAt(0);
        winrt::Windows::Storage::Streams::DataReader reader(input);
        const uint32_t loaded = reader.LoadAsync(static_cast<uint32_t>(size)).get();
        if (loaded != size) return false;
        auto bytes = std::unique_ptr<uint8_t[]>(new (std::nothrow) uint8_t[loaded]);
        if (!bytes) return false;
        reader.ReadBytes(winrt::array_view<uint8_t>(bytes.get(), bytes.get() + loaded));
        artwork->bytes = bytes.release();
        artwork->length = loaded;
        return true;
    } catch (...) {
        return false;
    }
}

extern "C" void weaver_media_select_source_app(const char *raw_id, const char *resolved_name, char output[257]) {
    if (!output) return;
    const std::string selected = select_source_app(raw_id ? raw_id : "", resolved_name ? resolved_name : "");
    const size_t length = std::min<size_t>(selected.size(), 256);
    std::memcpy(output, selected.data(), length);
    output[length] = '\0';
}

extern "C" WeaverMediaSession *weaver_media_create(void) {
    try {
        auto state = std::make_unique<WeaverMediaSession>();
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        state->apartment_initialized = true;
        state->manager = winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
        state->manager_token = state->manager.CurrentSessionChanged(
            [raw = state.get()](const auto &, const auto &) {
                if (!raw->shutting_down.load(std::memory_order_acquire)) raw->dirty.mark_session();
            });
        state->manager_subscribed = true;
        return state.release();
    } catch (...) {
        return nullptr;
    }
}

extern "C" void weaver_media_destroy(WeaverMediaSession *session) { delete session; }

extern "C" int weaver_media_poll(WeaverMediaSession *state, WeaverMediaState *output, WeaverMediaArtwork *artwork) {
    if (!state || !output || !artwork) return -1;
    std::memset(output, 0, sizeof(*output));
    std::memset(artwork, 0, sizeof(*artwork));
    try {
        const bool session_changed = state->dirty.take_session();
        if (session_changed) {
            rebind_current_session(state);
            artwork->changed = 1;
        }
        const auto session = state->current;
        if (!session) return 0;
        if (state->dirty.take_properties()) {
            try {
                const auto properties = session.TryGetMediaPropertiesAsync().get();
                state->title = winrt::to_string(properties.Title());
                state->artist = winrt::to_string(properties.Artist());
                state->album = winrt::to_string(properties.AlbumTitle());
                state->refresh_failed = !read_thumbnail(properties.Thumbnail(), artwork);
            } catch (...) {
                state->refresh_failed = true;
            }
        }
        artwork->refresh_failed = state->refresh_failed ? 1 : 0;
        copy_text(output->title, state->title);
        copy_text(output->artist, state->artist);
        copy_text(output->album, state->album);
        copy_text(output->source_app, state->source_app);
        const auto playback = session.GetPlaybackInfo();
        switch (playback.PlaybackStatus()) {
            case winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing:
                output->status = WEAVER_MEDIA_STATUS_PLAYING;
                break;
            case winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionPlaybackStatus::Paused:
                output->status = WEAVER_MEDIA_STATUS_PAUSED;
                break;
            default:
                output->status = WEAVER_MEDIA_STATUS_STOPPED;
                break;
        }
        output->playing = output->status == WEAVER_MEDIA_STATUS_PLAYING;
        const auto timeline = session.GetTimelineProperties();
        output->position_ms = std::chrono::duration_cast<std::chrono::milliseconds>(timeline.Position()).count();
        output->duration_ms = std::chrono::duration_cast<std::chrono::milliseconds>(timeline.EndTime() - timeline.StartTime()).count();
        output->position_ms = std::max<int64_t>(0, output->position_ms);
        output->duration_ms = std::max<int64_t>(0, output->duration_ms);
        return 1;
    } catch (...) {
        return -2;
    }
}

extern "C" void weaver_media_artwork_release(WeaverMediaArtwork *artwork) {
    if (!artwork) return;
    delete[] artwork->bytes;
    std::memset(artwork, 0, sizeof(*artwork));
}

extern "C" int weaver_media_test_dirty_coalescing(void) {
    WeaverMediaDirtyFlags dirty;
    if (!dirty.take_session() || dirty.take_session()) return 0;
    if (!dirty.take_properties() || dirty.take_properties()) return 0;
    dirty.mark_properties();
    dirty.mark_properties();
    return dirty.take_properties() && !dirty.take_properties();
}
