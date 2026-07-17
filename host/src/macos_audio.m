#import "macos_audio.h"

#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

enum { WeaverAudioRingCapacity = 65536 };

struct WeaverAudioCapture {
    _Atomic int status;
    _Atomic int32_t error;
    _Atomic bool cancelled;
    _Atomic bool device_changed;
    _Atomic uint64_t read_index;
    _Atomic uint64_t write_index;
    _Atomic uint32_t references;
    bool listener_added;
#if defined(WEAVER_AUTOMATION_SEAM)
    bool automation;
    double automation_phase;
    char automation_control[1024];
#endif
    AudioObjectID tap;
    AudioObjectID aggregate;
    AudioDeviceIOProcID io_proc;
    AudioStreamBasicDescription format;
    float ring[WeaverAudioRingCapacity];
};

static AudioObjectPropertyAddress WeaverAudioProperty(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){
        .mSelector = selector,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
}

static OSStatus WeaverGetTapProperty(AudioObjectID tap,
                                     AudioObjectPropertySelector selector,
                                     void *value,
                                     UInt32 *size) {
    AudioObjectPropertyAddress address = WeaverAudioProperty(selector);
    return AudioObjectGetPropertyData(tap, &address, 0, NULL, size, value);
}

static AudioObjectPropertyAddress WeaverDefaultOutputAddress(void) {
    return WeaverAudioProperty(kAudioHardwarePropertyDefaultOutputDevice);
}

static OSStatus WeaverDefaultOutputChanged(AudioObjectID object,
                                           UInt32 count,
                                           const AudioObjectPropertyAddress *addresses,
                                           void *context) {
    (void)object;
    (void)count;
    (void)addresses;
    WeaverAudioCapture *state = context;
    if (state) atomic_store_explicit(&state->device_changed, true, memory_order_release);
    return noErr;
}

static void WeaverPushSamples(WeaverAudioCapture *state, const AudioBufferList *input) {
    if (!state || !input || input->mNumberBuffers == 0) return;
    if (state->format.mFormatID != kAudioFormatLinearPCM ||
        (state->format.mFormatFlags & kAudioFormatFlagIsFloat) == 0 ||
        state->format.mBitsPerChannel != 32) return;
    uint64_t write = atomic_load_explicit(&state->write_index, memory_order_relaxed);
    const uint64_t read = atomic_load_explicit(&state->read_index, memory_order_acquire);
    for (UInt32 buffer_index = 0; buffer_index < input->mNumberBuffers; buffer_index++) {
        const AudioBuffer *buffer = &input->mBuffers[buffer_index];
        const float *samples = buffer->mData;
        const size_t count = buffer->mDataByteSize / sizeof(float);
        if (!samples) continue;
        for (size_t index = 0; index < count; index++) {
            if (write - read >= WeaverAudioRingCapacity) break;
            const float sample = samples[index];
            state->ring[write % WeaverAudioRingCapacity] = isfinite(sample) ? fmaxf(-1.0f, fminf(1.0f, sample)) : 0.0f;
            write += 1;
        }
    }
    atomic_store_explicit(&state->write_index, write, memory_order_release);
}

static void WeaverAudioCleanup(WeaverAudioCapture *state) {
#if defined(WEAVER_AUTOMATION_SEAM)
    if (state->automation) {
        free(state);
        return;
    }
#endif
    if (state->listener_added) {
        AudioObjectPropertyAddress output = WeaverDefaultOutputAddress();
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &output, WeaverDefaultOutputChanged, state);
    }
    if (state->io_proc && state->aggregate != kAudioObjectUnknown) {
        AudioDeviceStop(state->aggregate, state->io_proc);
        AudioDeviceDestroyIOProcID(state->aggregate, state->io_proc);
    }
    if (state->aggregate != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(state->aggregate);
    if (state->tap != kAudioObjectUnknown) AudioHardwareDestroyProcessTap(state->tap);
    free(state);
}

static void WeaverAudioRelease(WeaverAudioCapture *state) {
    if (atomic_fetch_sub_explicit(&state->references, 1, memory_order_acq_rel) == 1) WeaverAudioCleanup(state);
}

static int WeaverFailureStatus(OSStatus status) {
    if (status == kAudioDevicePermissionsError) return WEAVER_AUDIO_PERMISSION_DENIED;
    if (status == kAudioHardwareBadDeviceError || status == kAudioHardwareBadObjectError ||
        status == kAudioHardwareNotReadyError || status == kAudioHardwareNotRunningError) {
        return WEAVER_AUDIO_DEVICE_UNAVAILABLE;
    }
    return WEAVER_AUDIO_CAPTURE_FAILED;
}

static NSArray<NSNumber *> *WeaverExcludedProcesses(void) {
    pid_t pid = getpid();
    AudioObjectID process = kAudioObjectUnknown;
    UInt32 size = sizeof(process);
    AudioObjectPropertyAddress address = WeaverAudioProperty(kAudioHardwarePropertyTranslatePIDToProcessObject);
    const OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
        sizeof(pid), &pid, &size, &process);
    if (status != noErr || process == kAudioObjectUnknown) return @[];
    return @[@(process)];
}

static OSStatus WeaverSetUpCapture(WeaverAudioCapture *state) {
    CATapDescription *description = [[CATapDescription alloc] initMonoGlobalTapButExcludeProcesses:WeaverExcludedProcesses()];
    description.name = @"Weaver System Audio";
    description.privateTap = YES;
    description.muteBehavior = CATapUnmuted;
    OSStatus status = AudioHardwareCreateProcessTap(description, &state->tap);
    if (status != noErr) return status;

    CFStringRef tap_uid = NULL;
    UInt32 uid_size = sizeof(tap_uid);
    status = WeaverGetTapProperty(state->tap, kAudioTapPropertyUID, &tap_uid, &uid_size);
    if (status != noErr || !tap_uid) return status == noErr ? kAudioHardwareUnspecifiedError : status;
    UInt32 format_size = sizeof(state->format);
    status = WeaverGetTapProperty(state->tap, kAudioTapPropertyFormat, &state->format, &format_size);
    if (status != noErr) {
        CFRelease(tap_uid);
        return status;
    }

    NSDictionary *aggregate_description = @{
        @kAudioAggregateDeviceNameKey: @"Weaver System Audio",
        @kAudioAggregateDeviceUIDKey: [NSString stringWithFormat:@"com.sunkenintime.weaver.audio.%@", NSUUID.UUID.UUIDString],
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceTapAutoStartKey: @NO,
        @kAudioAggregateDeviceTapListKey: @[@{
            @kAudioSubTapUIDKey: (__bridge NSString *)tap_uid,
            @kAudioSubTapDriftCompensationKey: @YES,
        }],
    };
    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate_description, &state->aggregate);
    CFRelease(tap_uid);
    if (status != noErr) return status;

    status = AudioDeviceCreateIOProcIDWithBlock(&state->io_proc, state->aggregate, NULL,
        ^(const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *input_time,
          AudioBufferList *output, const AudioTimeStamp *output_time) {
            (void)now;
            (void)input_time;
            (void)output;
            (void)output_time;
            if (!atomic_load_explicit(&state->cancelled, memory_order_acquire)) WeaverPushSamples(state, input);
        });
    if (status != noErr) return status;
    AudioObjectPropertyAddress output = WeaverDefaultOutputAddress();
    if (AudioObjectAddPropertyListener(kAudioObjectSystemObject, &output, WeaverDefaultOutputChanged, state) == noErr) {
        state->listener_added = true;
    }
    return AudioDeviceStart(state->aggregate, state->io_proc);
}

static void *WeaverAudioWorker(void *context) {
    WeaverAudioCapture *state = context;
    @autoreleasepool {
        const OSStatus status = WeaverSetUpCapture(state);
        atomic_store_explicit(&state->error, status, memory_order_release);
        atomic_store_explicit(&state->status,
            status == noErr ? WEAVER_AUDIO_RUNNING : WeaverFailureStatus(status), memory_order_release);
    }
    WeaverAudioRelease(state);
    return NULL;
}

#if defined(WEAVER_AUTOMATION_SEAM)
static char WeaverAutomationMode(const WeaverAudioCapture *state);
#endif

WeaverAudioCapture *weaver_audio_create(void) {
    WeaverAudioCapture *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    atomic_store_explicit(&state->references, 1, memory_order_relaxed);
    state->tap = kAudioObjectUnknown;
    state->aggregate = kAudioObjectUnknown;
    atomic_store_explicit(&state->status, WEAVER_AUDIO_STARTING, memory_order_relaxed);

#if defined(WEAVER_AUTOMATION_SEAM)
    const char *automation = getenv("WEAVER_AUTOMATION");
    const char *control = getenv("WEAVER_AUDIO_TEST_CONTROL");
    if (automation && strcmp(automation, "1") == 0 && control && control[0] != '\0') {
        state->automation = true;
        state->format.mFormatID = kAudioFormatLinearPCM;
        state->format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        state->format.mSampleRate = 48000;
        state->format.mChannelsPerFrame = 1;
        state->format.mBytesPerFrame = sizeof(float);
        state->format.mBitsPerChannel = 32;
        snprintf(state->automation_control, sizeof(state->automation_control), "%s", control);
        const char mode = WeaverAutomationMode(state);
        if (mode == 'p' || mode == 'r') {
            atomic_store_explicit(&state->error, kAudioDevicePermissionsError, memory_order_release);
            atomic_store_explicit(&state->status, WEAVER_AUDIO_PERMISSION_DENIED, memory_order_release);
        } else {
            atomic_store_explicit(&state->status, WEAVER_AUDIO_RUNNING, memory_order_release);
        }
        return state;
    }
#endif

    pthread_t thread;
    atomic_fetch_add_explicit(&state->references, 1, memory_order_relaxed);
    if (pthread_create(&thread, NULL, WeaverAudioWorker, state) != 0) {
        WeaverAudioRelease(state);
        atomic_store_explicit(&state->status, WEAVER_AUDIO_CAPTURE_FAILED, memory_order_release);
        return state;
    }
    pthread_detach(thread);
    return state;
}

void weaver_audio_destroy(WeaverAudioCapture *state) {
    if (!state) return;
    atomic_store_explicit(&state->cancelled, true, memory_order_release);
    WeaverAudioRelease(state);
}

int weaver_audio_status(const WeaverAudioCapture *state) {
    return state ? atomic_load_explicit(&state->status, memory_order_acquire) : WEAVER_AUDIO_CAPTURE_FAILED;
}

int32_t weaver_audio_error(const WeaverAudioCapture *state) {
    return state ? atomic_load_explicit(&state->error, memory_order_acquire) : kAudioHardwareUnspecifiedError;
}

uint32_t weaver_audio_sample_rate(const WeaverAudioCapture *state) {
    return state ? (uint32_t)state->format.mSampleRate : 0;
}

int weaver_audio_default_device_is_current(const WeaverAudioCapture *state) {
    return state && !atomic_load_explicit(&state->device_changed, memory_order_acquire);
}

#if defined(WEAVER_AUTOMATION_SEAM)
static char WeaverAutomationMode(const WeaverAudioCapture *state) {
    FILE *file = fopen(state->automation_control, "r");
    if (!file) return 's';
    const int mode = fgetc(file);
    fclose(file);
    return mode == EOF ? 's' : (char)mode;
}
#endif

int weaver_audio_poll(WeaverAudioCapture *state, float *mono, size_t capacity, size_t *sample_count) {
    if (!state || !mono || !sample_count) return -1;
    *sample_count = 0;
    const int status = weaver_audio_status(state);
    if (status == WEAVER_AUDIO_STARTING) return 0;
    if (status != WEAVER_AUDIO_RUNNING) return -2;
#if defined(WEAVER_AUTOMATION_SEAM)
    if (state->automation) {
        const char mode = WeaverAutomationMode(state);
        if (mode == 'p' || mode == 'r') {
            atomic_store_explicit(&state->error, kAudioDevicePermissionsError, memory_order_release);
            atomic_store_explicit(&state->status, WEAVER_AUDIO_PERMISSION_DENIED, memory_order_release);
            return -2;
        }
        if (mode == 'f') {
            atomic_store_explicit(&state->error, kAudioHardwareBadDeviceError, memory_order_release);
            atomic_store_explicit(&state->status, WEAVER_AUDIO_DEVICE_UNAVAILABLE, memory_order_release);
            return -2;
        }
        const size_t count = capacity < 1440 ? capacity : 1440;
        for (size_t index = 0; index < count; index++) {
            mono[index] = mode == 'a' ? (float)(0.35 * sin(state->automation_phase)) : 0.0f;
            state->automation_phase += 2.0 * M_PI * 440.0 / 48000.0;
        }
        *sample_count = count;
        return 0;
    }
#endif
    uint64_t read = atomic_load_explicit(&state->read_index, memory_order_relaxed);
    const uint64_t write = atomic_load_explicit(&state->write_index, memory_order_acquire);
    const size_t available = (size_t)(write - read);
    const size_t count = available < capacity ? available : capacity;
    for (size_t index = 0; index < count; index++) {
        mono[index] = state->ring[(read + index) % WeaverAudioRingCapacity];
    }
    atomic_store_explicit(&state->read_index, read + count, memory_order_release);
    *sample_count = count;
    return 0;
}
