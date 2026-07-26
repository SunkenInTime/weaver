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
#import "utility/helpers.h"

void adapter_seek(long position) {

    if (position < 0) {
        failf(@"Negative values are not allowed: %d", position);
    }

    g_mediaRemote.setElapsedTime(position / 1000000.0);
    const double requested = position / 1000000.0;
    const NSTimeInterval started = [NSDate timeIntervalSinceReferenceDate];
    __block NSNumber *observed = nil;
    __block bool playing = false;
    dispatch_group_t group = dispatch_group_create();

    dispatch_group_enter(group);
    g_mediaRemote.getNowPlayingInfo(
        g_serialdispatchQueue, ^(NSDictionary *information) {
          observed = getElapsedTimeNow(information);
          dispatch_group_leave(group);
        });
    dispatch_group_enter(group);
    g_mediaRemote.getNowPlayingApplicationIsPlaying(
        g_serialdispatchQueue, ^(bool isPlaying) {
          playing = isPlaying;
          dispatch_group_leave(group);
        });

    const dispatch_time_t timeout =
        dispatch_time(DISPATCH_TIME_NOW, 2000 * NSEC_PER_MSEC);
    if (dispatch_group_wait(group, timeout) != 0 || observed == nil) {
        decline(@"Seek read-back was unavailable");
    }
    const NSTimeInterval elapsed =
        [NSDate timeIntervalSinceReferenceDate] - started;
    const double expected = requested + (playing ? elapsed : 0);
    if (fabs([observed doubleValue] - expected) > 2.0) {
        declinef(@"Seek read-back was outside tolerance: requested %.3f, "
                  @"observed %.3f",
                 requested, [observed doubleValue]);
    }
}

static inline long seek_0_position() {
    return getEnvFuncParamLongSafe(@"adapter_seek", 0, @"position");
}

void adapter_seek_env() { adapter_seek(seek_0_position()); }
