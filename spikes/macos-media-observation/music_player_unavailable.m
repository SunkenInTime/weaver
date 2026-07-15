#import <MediaPlayer/MediaPlayer.h>

int main(void) {
    MPMusicPlayerController *controller = MPMusicPlayerController.systemMusicPlayer;
    return controller == nil;
}

