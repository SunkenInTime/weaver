#include "renderer_server.h"
#include "d3d_presenter.h"
#include "renderer_protocol.h"

#include <windows.h>

#include <cstdio>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

static wchar_t rendererLogPath[32768] = {};
static std::mutex rendererLogMutex;

static void logEvent(const char *kind, DWORD widget_pid, uint64_t frames, uint64_t elapsed_ms) {
    if (rendererLogPath[0] == L'\0') return;
    char line[256] = {};
    const int length = snprintf(line, sizeof(line), "%llu %s renderer=%lu widget=%lu frames=%llu elapsed_ms=%llu\r\n",
        (unsigned long long)GetTickCount64(), kind, (unsigned long)GetCurrentProcessId(),
        (unsigned long)widget_pid, (unsigned long long)frames, (unsigned long long)elapsed_ms);
    if (length <= 0) return;
    std::lock_guard<std::mutex> lock(rendererLogMutex);
    HANDLE file = CreateFileW(rendererLogPath, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(file, line, (DWORD)length, &written, nullptr);
    CloseHandle(file);
}

static bool readExact(HANDLE file, void *bytes, size_t length) {
    uint8_t *cursor = static_cast<uint8_t *>(bytes);
    while (length > 0) {
        DWORD read = 0;
        if (!ReadFile(file, cursor, (DWORD)length, &read, nullptr) || read == 0) return false;
        cursor += read;
        length -= read;
    }
    return true;
}

static bool writeExact(HANDLE file, const void *bytes, size_t length) {
    const uint8_t *cursor = static_cast<const uint8_t *>(bytes);
    while (length > 0) {
        DWORD written = 0;
        if (!WriteFile(file, cursor, (DWORD)length, &written, nullptr) || written == 0) return false;
        cursor += written;
        length -= written;
    }
    return true;
}

static void serveWidget(HANDLE pipe, NativeSdkD3DSharedRenderer *renderer) {
    NativeSdkD3DSharedSurface *surface = nullptr;
    DWORD widget_pid = 0;
    uint64_t frames = 0;
    uint64_t interval_start_ms = GetTickCount64();
    for (;;) {
        WeaverRendererFrame frame = {};
        if (!readExact(pipe, &frame, sizeof(frame))) break;
        WeaverRendererReply reply = {};
        reply.magic = kWeaverRendererMagic;
        reply.version = kWeaverRendererVersion;
        if (frame.magic != kWeaverRendererMagic ||
            frame.version != kWeaverRendererVersion || frame.widget_pid == 0 ||
            frame.packet_len == 0 || frame.packet_len > kWeaverRendererMaxPacket) {
            writeExact(pipe, &reply, sizeof(reply));
            break;
        }
        if (!surface) {
            widget_pid = frame.widget_pid;
            surface = nativeSdkD3DSharedSurfaceCreate(renderer, widget_pid, nullptr);
            logEvent("connect", widget_pid, 0, 0);
        }
        if (!surface || widget_pid != frame.widget_pid) break;
        std::vector<uint8_t> packet(frame.packet_len);
        if (!readExact(pipe, packet.data(), packet.size())) break;
        uint64_t replacement_handle = 0;
        if (nativeSdkD3DSharedSurfacePresent(surface, frame.logical_width,
            frame.logical_height, frame.scale, frame.clear_r, frame.clear_g,
            frame.clear_b, frame.clear_a, packet.data(), packet.size(),
            &replacement_handle)) {
            reply.status = 1;
            reply.surface_handle = replacement_handle;
            frames += 1;
            if (frames % 300 == 0) {
                const uint64_t now = GetTickCount64();
                logEvent("fps", widget_pid, 300, now - interval_start_ms);
                interval_start_ms = now;
            }
        }
        if (!writeExact(pipe, &reply, sizeof(reply)) || reply.status == 0) break;
    }
    nativeSdkD3DSharedSurfaceDestroy(surface);
    logEvent("disconnect", widget_pid, frames, 0);
    FlushFileBuffers(pipe);
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
}

int weaver_renderer_run(void) {
    wchar_t pipe_name[512] = {};
    const DWORD length = GetEnvironmentVariableW(L"WEAVER_RENDERER_PIPE",
        pipe_name, ARRAYSIZE(pipe_name));
    if (length == 0 || length >= ARRAYSIZE(pipe_name)) return 2;
    GetEnvironmentVariableW(L"WEAVER_RENDERER_LOG", rendererLogPath, ARRAYSIZE(rendererLogPath));
    NativeSdkD3DSharedRenderer *renderer = nativeSdkD3DSharedRendererCreate();
    if (!renderer) return 3;
    logEvent("start", 0, 0, 0);
    for (;;) {
        HANDLE pipe = CreateNamedPipeW(pipe_name,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            PIPE_UNLIMITED_INSTANCES, 1024 * 1024, 1024 * 1024, 0, nullptr);
        if (pipe == INVALID_HANDLE_VALUE) break;
        const BOOL connected = ConnectNamedPipe(pipe, nullptr) ? TRUE :
            GetLastError() == ERROR_PIPE_CONNECTED;
        if (!connected) {
            CloseHandle(pipe);
            continue;
        }
        std::thread(serveWidget, pipe, renderer).detach();
    }
    nativeSdkD3DSharedRendererDestroy(renderer);
    return 4;
}
