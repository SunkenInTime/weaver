#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>

static void writeJSON(NSDictionary *value) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value
                                                   options:NSJSONWritingSortedKeys
                                                     error:&error];
    if (!data) {
        fprintf(stderr, "macos-media-observation: JSON serialization failed: %s\n",
                error.localizedDescription.UTF8String);
        exit(2);
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fwrite("\n", 1, 1, stdout);
    fflush(stdout);
}

static NSDictionary *snapshot(NSString *mode, MPNowPlayingInfoCenter *center) {
    NSDictionary *info = center.nowPlayingInfo;
    id title = info[MPMediaItemPropertyTitle];
    id artist = info[MPMediaItemPropertyArtist];
    id album = info[MPMediaItemPropertyAlbumTitle];
    return @{
        @"mode": mode,
        @"pid": @(NSProcessInfo.processInfo.processIdentifier),
        @"hasNowPlayingInfo": info != nil ? @YES : @NO,
        @"title": title ?: [NSNull null],
        @"artist": artist ?: [NSNull null],
        @"album": album ?: [NSNull null],
        @"playbackState": @((NSInteger)center.playbackState),
    };
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: %s publish|observe\n", argv[0]);
            return 2;
        }

        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
        if ([mode isEqualToString:@"publish"]) {
            center.nowPlayingInfo = @{
                MPMediaItemPropertyTitle: @"Weaver Public API Probe",
                MPMediaItemPropertyArtist: @"Weaver",
                MPMediaItemPropertyAlbumTitle: @"macOS M11",
                MPMediaItemPropertyPlaybackDuration: @180,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: @42,
                MPNowPlayingInfoPropertyPlaybackRate: @1,
            };
            center.playbackState = MPNowPlayingPlaybackStatePlaying;
            writeJSON(snapshot(mode, center));
            [NSThread sleepForTimeInterval:2.0];
            center.nowPlayingInfo = nil;
            center.playbackState = MPNowPlayingPlaybackStateStopped;
            return 0;
        }
        if ([mode isEqualToString:@"observe"]) {
            writeJSON(snapshot(mode, center));
            return 0;
        }

        fprintf(stderr, "unknown mode: %s\n", argv[1]);
        return 2;
    }
}
