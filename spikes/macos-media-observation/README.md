# macOS public Now Playing observation spike

This is a disposable PR 14 decision harness, not a production provider. It
tests the two plausible public MediaPlayer routes at Weaver's macOS 14.2 floor.

Run:

```sh
spikes/macos-media-observation/build.sh
```

The harness holds a publisher process open after setting title, artist, album,
duration, position, playback rate, and state through
`MPNowPlayingInfoCenter`. A second concurrent process reads its own default
center. The publisher must read back its values while the observer sees no
Now Playing dictionary. This demonstrates application-local publication; it
does not claim to discover the system's active player.

The same script compiles a negative probe for
`MPMusicPlayerController.systemMusicPlayer` and requires the installed public
macOS SDK to reject it as unavailable. Output and the exact compiler diagnostic
are written below the ignored `build/` directory and summarized in
`docs/macos-m11-data.json`.

The spike intentionally does not link or dynamically load MediaRemote. That
framework is private and cannot become an accidental shipping dependency just
to make a feasibility test pass.
