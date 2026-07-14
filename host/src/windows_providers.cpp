#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define WINRT_LEAN_AND_MEAN

#include "windows_providers.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <windows.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/base.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
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

struct WeaverMediaSession {
    winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionManager manager{nullptr};
    bool apartment_initialized = false;

    ~WeaverMediaSession() {
        manager = nullptr;
        if (apartment_initialized) winrt::uninit_apartment();
    }
};

static void copy_text(char (&destination)[512], const winrt::hstring &source) {
    const std::string utf8 = winrt::to_string(source);
    const size_t length = std::min(utf8.size(), sizeof(destination) - 1);
    std::memcpy(destination, utf8.data(), length);
    destination[length] = '\0';
}

extern "C" WeaverMediaSession *weaver_media_create(void) {
    try {
        auto state = std::make_unique<WeaverMediaSession>();
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        state->apartment_initialized = true;
        state->manager = winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
        return state.release();
    } catch (...) {
        return nullptr;
    }
}

extern "C" void weaver_media_destroy(WeaverMediaSession *session) { delete session; }

extern "C" int weaver_media_poll(WeaverMediaSession *state, WeaverMediaState *output) {
    if (!state || !output) return -1;
    std::memset(output, 0, sizeof(*output));
    try {
        const auto session = state->manager.GetCurrentSession();
        if (!session) return 0;
        const auto properties = session.TryGetMediaPropertiesAsync().get();
        copy_text(output->title, properties.Title());
        copy_text(output->artist, properties.Artist());
        copy_text(output->album, properties.AlbumTitle());
        const auto playback = session.GetPlaybackInfo();
        output->playing = playback.PlaybackStatus() == winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing;
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
