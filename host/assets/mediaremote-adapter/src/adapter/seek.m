// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#include "private/MediaRemote.h"
#include <limits.h>
#include <math.h>

#import <Foundation/Foundation.h>

#import "MediaRemoteAdapter.h"
#import "adapter/env.h"
#import "adapter/globals.h"
#import "adapter/now_playing.h"
#import "adapter/seek_verifier.h"
#import "utility/helpers.h"

void adapter_seek(long position) {

    if (position < 0) {
        failf(@"Negative values are not allowed: %d", position);
    }

    g_mediaRemote.setElapsedTime(position / 1000000.0);
    const double requested = position / 1000000.0;
    const NSTimeInterval started = [NSDate timeIntervalSinceReferenceDate];
    const NSTimeInterval deadline = started + 2.0;
    MRASeekVerifier verifier = mra_seek_verifier_create(requested);

    // MediaRemote's void setter is eventually consistent for some players.
    // Observe repeatedly until the requested position converges or the full
    // two-second verification window expires.
    while ([NSDate timeIntervalSinceReferenceDate] < deadline) {
        __block NSDictionary *information = nil;
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        g_mediaRemote.getNowPlayingInfo(
            g_serialdispatchQueue, ^(NSDictionary *value) {
              information = value;
              dispatch_group_leave(group);
            });

        const NSTimeInterval remaining =
            deadline - [NSDate timeIntervalSinceReferenceDate];
        if (remaining <= 0) {
            break;
        }
        const int64_t waitNanos =
            (int64_t)(MIN(remaining, 0.25) * NSEC_PER_SEC);
        if (dispatch_group_wait(
                group, dispatch_time(DISPATCH_TIME_NOW, waitNanos)) == 0) {
            NSNumber *observed = nil;
            double playbackRate = 0;
            if (information != nil) {
                id rateValue =
                    information[kMRMediaRemoteNowPlayingInfoPlaybackRate];
                if (rateValue != nil) {
                    if (![rateValue isKindOfClass:[NSNumber class]]) {
                        failf(@"Seek read-back contained an invalid playback "
                              @"rate");
                    }
                    playbackRate = [(NSNumber *)rateValue doubleValue];
                    if (!isfinite(playbackRate) || playbackRate < 0 ||
                        playbackRate > 16) {
                        failf(@"Seek read-back contained an invalid playback "
                              @"rate: %.3f",
                              playbackRate);
                    }
                }
                observed = getElapsedTimeNow(information);
            }
            const NSTimeInterval elapsed =
                [NSDate timeIntervalSinceReferenceDate] - started;
            mra_seek_verifier_observe(
                &verifier, information != nil, observed != nil,
                observed != nil ? [observed doubleValue] : 0, elapsed,
                playbackRate);
            if (verifier.verdict == MRASeekAccepted) {
                return;
            }
        }
        [NSThread sleepForTimeInterval:0.05];
    }

    switch (mra_seek_verifier_finish(&verifier)) {
    case MRASeekTimedOut:
        decline(@"Seek read-back timed out");
        break;
    case MRASeekNoSession:
        decline(@"Seek read-back found no active session");
        break;
    case MRASeekUnavailable:
        decline(@"Seek read-back was unavailable");
        break;
    case MRASeekOutOfTolerance:
        declinef(@"Seek read-back was outside tolerance: requested %.3f, "
                 @"observed %.3f",
                 verifier.lastExpected, verifier.lastObserved);
        break;
    case MRASeekAccepted:
        return;
    case MRASeekPending:
        decline(@"Seek read-back did not settle");
        break;
    }
}

static inline long seek_0_position() {
    return getEnvFuncParamLongSafe(@"adapter_seek", 0, @"position");
}

void adapter_seek_env() { adapter_seek(seek_0_position()); }
