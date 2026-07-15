#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <math.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

#if defined(__arm64__)
static const char *SpikeArchitecture = "arm64";
#elif defined(__x86_64__)
static const char *SpikeArchitecture = "x86_64";
#else
static const char *SpikeArchitecture = "unknown";
#endif

typedef struct {
    uint64_t callbacks;
    uint64_t frames;
    uint64_t fanout_frames;
    uint64_t first_callback_ns;
    uint64_t first_signal_ns;
    double peak_rms;
    long double rms_sum;
    uint64_t rms_count;
    NSUInteger fanout;
    AudioStreamBasicDescription format;
} SpikeMetrics;

static uint64_t monotonicNanoseconds(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    return mach_continuous_time() * timebase.numer / timebase.denom;
}

static NSString *fourCC(OSStatus status) {
    uint32_t value = CFSwapInt32HostToBig((uint32_t)status);
    char bytes[5] = {0};
    memcpy(bytes, &value, 4);
    for (NSUInteger index = 0; index < 4; index++) {
        if (bytes[index] < 32 || bytes[index] > 126) return @"";
    }
    return [NSString stringWithUTF8String:bytes] ?: @"";
}

static NSDictionary *statusJSON(OSStatus status) {
    return @{ @"code": @(status), @"fourcc": fourCC(status) };
}

static OSStatus getTapProperty(AudioObjectID tap, AudioObjectPropertySelector selector, void *value, UInt32 *size) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    return AudioObjectGetPropertyData(tap, &address, 0, NULL, size, value);
}

static double bufferRMS(const AudioBufferList *buffers, const AudioStreamBasicDescription *format) {
    if (!buffers || format->mFormatID != kAudioFormatLinearPCM ||
        (format->mFormatFlags & kAudioFormatFlagIsFloat) == 0 || format->mBitsPerChannel != 32) return 0;
    long double sum = 0;
    uint64_t count = 0;
    for (UInt32 bufferIndex = 0; bufferIndex < buffers->mNumberBuffers; bufferIndex++) {
        const AudioBuffer *buffer = &buffers->mBuffers[bufferIndex];
        const float *samples = buffer->mData;
        const uint64_t sampleCount = buffer->mDataByteSize / sizeof(float);
        if (!samples) continue;
        for (uint64_t index = 0; index < sampleCount; index++) {
            const double sample = samples[index];
            if (!isfinite(sample)) continue;
            sum += sample * sample;
            count += 1;
        }
    }
    return count == 0 ? 0 : sqrt((double)(sum / count));
}

static NSString *argumentValue(NSArray<NSString *> *arguments, NSString *name) {
    const NSUInteger index = [arguments indexOfObject:name];
    if (index == NSNotFound || index + 1 >= arguments.count) return nil;
    return arguments[index + 1];
}

static void writeResult(NSDictionary *result, NSString *outputPath) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data) {
        fprintf(stderr, "audio-tap-spike: JSON serialization failed: %s\n", error.localizedDescription.UTF8String);
        return;
    }
    NSMutableData *line = [data mutableCopy];
    [line appendBytes:"\n" length:1];
    if (outputPath.length > 0) {
        if (![line writeToFile:outputPath options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr, "audio-tap-spike: result write failed: %s\n", error.localizedDescription.UTF8String);
        }
    } else {
        fwrite(line.bytes, 1, line.length, stdout);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        const NSTimeInterval duration = MAX(0.5, [argumentValue(arguments, @"--duration") doubleValue] ?: 4.0);
        const NSUInteger fanout = MAX(1, [argumentValue(arguments, @"--fanout") integerValue] ?: 1);
        const BOOL setupOnly = [arguments containsObject:@"--setup-only"];
        NSString *outputPath = argumentValue(arguments, @"--output");
        NSString *soundPath = argumentValue(arguments, @"--play-sound");
        const uint64_t launchNs = monotonicNanoseconds();
        __block SpikeMetrics metrics = { .fanout = fanout };
        AudioObjectID tap = kAudioObjectUnknown;
        AudioObjectID aggregate = kAudioObjectUnknown;
        AudioDeviceIOProcID ioProc = NULL;
        OSStatus tapStatus = noErr;
        OSStatus uidStatus = noErr;
        OSStatus formatStatus = noErr;
        OSStatus aggregateStatus = noErr;
        OSStatus ioProcStatus = noErr;
        OSStatus startStatus = noErr;
        OSStatus stopStatus = noErr;
        pid_t soundPid = 0;
        uint64_t soundLaunchNs = 0;

        if (@available(macOS 14.2, *)) {
            CATapDescription *description = [[CATapDescription alloc] initMonoGlobalTapButExcludeProcesses:@[]];
            description.name = @"Weaver Audio Tap Spike";
            description.privateTap = YES;
            description.muteBehavior = CATapUnmuted;
            tapStatus = AudioHardwareCreateProcessTap(description, &tap);
            if (tapStatus == noErr) {
                CFStringRef tapUID = NULL;
                UInt32 uidSize = sizeof(tapUID);
                uidStatus = getTapProperty(tap, kAudioTapPropertyUID, &tapUID, &uidSize);
                UInt32 formatSize = sizeof(metrics.format);
                formatStatus = getTapProperty(tap, kAudioTapPropertyFormat, &metrics.format, &formatSize);
                if (uidStatus == noErr && tapUID) {
                    NSString *aggregateUID = [NSString stringWithFormat:@"com.sunkenintime.weaver.audio-tap-spike.%@", NSUUID.UUID.UUIDString];
                    NSDictionary *aggregateDescription = @{
                        @kAudioAggregateDeviceNameKey: @"Weaver Audio Tap Spike",
                        @kAudioAggregateDeviceUIDKey: aggregateUID,
                        @kAudioAggregateDeviceIsPrivateKey: @YES,
                        // Weaver must start cleanly during silence. Auto-start would make
                        // AudioDeviceStart wait for some tapped process to emit audio.
                        @kAudioAggregateDeviceTapAutoStartKey: @NO,
                        @kAudioAggregateDeviceTapListKey: @[@{
                            @kAudioSubTapUIDKey: (__bridge NSString *)tapUID,
                            @kAudioSubTapDriftCompensationKey: @YES,
                        }],
                    };
                    aggregateStatus = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregateDescription, &aggregate);
                    CFRelease(tapUID);
                }
            }

            dispatch_queue_t captureQueue = dispatch_queue_create("com.sunkenintime.weaver.audio-tap-spike.capture", DISPATCH_QUEUE_SERIAL);
            if (!setupOnly && aggregateStatus == noErr && aggregate != kAudioObjectUnknown) {
                ioProcStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, captureQueue,
                    ^(const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime,
                      AudioBufferList *output, const AudioTimeStamp *outputTime) {
                        (void)now; (void)inputTime; (void)output; (void)outputTime;
                        const uint64_t callbackNs = monotonicNanoseconds();
                        if (metrics.first_callback_ns == 0) metrics.first_callback_ns = callbackNs;
                        metrics.callbacks += 1;
                        const uint64_t frameCount = metrics.format.mBytesPerFrame == 0 || input->mNumberBuffers == 0
                            ? 0 : input->mBuffers[0].mDataByteSize / metrics.format.mBytesPerFrame;
                        metrics.frames += frameCount;
                        metrics.fanout_frames += frameCount * metrics.fanout;
                        const double rms = bufferRMS(input, &metrics.format);
                        if (rms > metrics.peak_rms) metrics.peak_rms = rms;
                        metrics.rms_sum += rms;
                        metrics.rms_count += 1;
                        if (rms > 0.0001 && metrics.first_signal_ns == 0) metrics.first_signal_ns = callbackNs;
                    });
            }
            if (!setupOnly && ioProcStatus == noErr && ioProc) startStatus = AudioDeviceStart(aggregate, ioProc);

            if (startStatus == noErr && soundPath.length > 0) {
                soundLaunchNs = monotonicNanoseconds();
                const char *playerArguments[] = { "/usr/bin/afplay", soundPath.fileSystemRepresentation, NULL };
                posix_spawn(&soundPid, playerArguments[0], NULL, NULL, (char *const *)playerArguments, environ);
            }
            [NSThread sleepForTimeInterval:duration];
            if (soundPid > 0) waitpid(soundPid, NULL, 0);
            if (startStatus == noErr && ioProc) stopStatus = AudioDeviceStop(aggregate, ioProc);
            dispatch_sync(captureQueue, ^{});
            if (ioProc) AudioDeviceDestroyIOProcID(aggregate, ioProc);
            if (aggregate != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(aggregate);
            if (tap != kAudioObjectUnknown) AudioHardwareDestroyProcessTap(tap);
        } else {
            tapStatus = kAudioHardwareUnsupportedOperationError;
        }

        const double firstCallbackMs = metrics.first_callback_ns == 0 ? -1 : (metrics.first_callback_ns - launchNs) / 1e6;
        const double signalAfterPlaybackMs = metrics.first_signal_ns == 0 || soundLaunchNs == 0 ? -1 : (metrics.first_signal_ns - soundLaunchNs) / 1e6;
        NSDictionary *result = @{
            @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"architecture": @(SpikeArchitecture),
            @"bundle": NSBundle.mainBundle.bundleIdentifier ?: [NSNull null],
            @"durationSeconds": @(duration),
            @"fanout": @(fanout),
            @"mode": setupOnly ? @"setup-only" : @"capture",
            @"statuses": @{
                @"createTap": statusJSON(tapStatus),
                @"readTapUID": statusJSON(uidStatus),
                @"readTapFormat": statusJSON(formatStatus),
                @"createAggregate": statusJSON(aggregateStatus),
                @"createIOProc": @{ @"attempted": @(!setupOnly), @"status": statusJSON(ioProcStatus) },
                @"start": @{ @"attempted": @(!setupOnly), @"status": statusJSON(startStatus) },
                @"stop": @{ @"attempted": @(!setupOnly), @"status": statusJSON(stopStatus) },
            },
            @"format": @{
                @"sampleRate": @(metrics.format.mSampleRate),
                @"channels": @(metrics.format.mChannelsPerFrame),
                @"bitsPerChannel": @(metrics.format.mBitsPerChannel),
                @"bytesPerFrame": @(metrics.format.mBytesPerFrame),
                @"flags": @(metrics.format.mFormatFlags),
            },
            @"metrics": @{
                @"callbacks": @(metrics.callbacks),
                @"frames": @(metrics.frames),
                @"fanoutFrames": @(metrics.fanout_frames),
                @"firstCallbackMs": @(firstCallbackMs),
                @"signalAfterPlaybackMs": @(signalAfterPlaybackMs),
                @"peakRms": @(metrics.peak_rms),
                @"meanCallbackRms": @(metrics.rms_count == 0 ? 0 : (double)(metrics.rms_sum / metrics.rms_count)),
            },
        };
        writeResult(result, outputPath);
        const OSStatus exitStatus = setupOnly ? aggregateStatus : startStatus;
        return exitStatus == noErr ? 0 : 1;
    }
}
