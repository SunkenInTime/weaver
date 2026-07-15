# macOS M11 — public media-provider feasibility and shipping decision

Recorded 2026-07-15 on a MacBook Air with Apple M2 (8 cores, 8 GB), macOS
26.5.1 (25F80), arm64, Xcode 16.0 (16A242d), Apple clang 16.0.0, and the macOS
15.0 SDK. The probe ran from Weaver base commit `bf9d6b5` on
`macos/14-media-decision`. Raw evidence is in
[`macos-m11-data.json`](macos-m11-data.json).

## Decision

There is no honest, public, distributable system-wide media provider at
Weaver's macOS 14.2 floor. ADR 0015 makes macOS `media` explicitly unavailable
for v0 and omits PR 15. The host sends no fabricated empty session, starts no
media poller, exposes no private API dependency, and does not change Widget
source or the shared provider shape.

This PR makes no media-runtime or performance claim. Its output is the shipping
decision, a disposable public-API probe, and the evidence needed to reject
routes that appear plausible from API names alone.

## Public API probe

Run:

```sh
spikes/macos-media-observation/build.sh
```

The script compiles an arm64 executable with deployment target 14.2. One
process publishes title, artist, album, duration, elapsed position, playback
rate, and playing state through `MPNowPlayingInfoCenter`, reads those values
back, and remains alive. A second concurrent process reads its default center.

| Process | Local Now Playing dictionary | Title | Playback state |
|---|---:|---|---:|
| Publisher | Present | `Weaver Public API Probe` | Playing (`1`) |
| Concurrent observer | Absent | `null` | Unknown (`0`) |

This is consistent with Apple's public documentation describing
[`MPNowPlayingInfoCenter`](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)
as an object for setting the media an app plays and the installed header's more
specific “current application” boundary. It disproves the assumption that a
second application's default center observes the active system player.

The same harness compiles a call to
`MPMusicPlayerController.systemMusicPlayer` and requires compilation to fail.
The macOS 15 SDK produced:

```text
error: 'MPMusicPlayerController' is unavailable: not available on macOS
```

The newer [`Now Playing` framework](https://developer.apple.com/documentation/nowplaying)
is a beta publication API for an application's own sessions. It is not in the
installed macOS 15 SDK, cannot be deployed to 14.2 from this toolchain, and
does not document a cross-application observation surface.

## Coverage and rejected routes

Installed application dictionaries were inspected rather than treated as one
generic API:

| Application | Available scripted state | Why it is not the Provider |
|---|---|---|
| Music 1.6.5 | Current track, player state/position, play/pause | Music-only adapter and Automation access |
| Spotify 1.2.89.539 | Track metadata, state/position, artwork URL, play/pause | Spotify-only adapter and Automation access |
| QuickTime Player 10.5 | Per-document current time/duration/rate | Document semantics, not active system media |
| Podcasts 1.1.0 | No scripting dictionary returned (`-192`) | No adapter surface |
| Safari 26.5 | No common media playback fields | Browser playback not covered |

Apple Events would therefore be incomplete, poll-based, player-specific, and
consent-sensitive. Apple documents both the required
[`NSAppleEventsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)
and the hardened-runtime
[`Apple Events entitlement`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events).
It remains a possible future opt-in integration, not system-wide parity.

`MediaRemote.framework` exists only in the installed private-framework surface.
There is no production link, symbol lookup, copied private header, or daemon
protocol in Weaver. Accessibility scraping, UI scripting, notification
scraping, player databases, and process inspection are likewise rejected.

## Honest unavailable behavior

macOS supports none of the existing media fields at v0. Artwork and media
commands remain outside the frozen contract and are not invented here. An
unavailable subscription receives no frames; it is not represented as an empty
title, stopped state, or zero duration. There is no media polling cadence or
privacy prompt. PR 16 will expose `mediaAvailability: "unavailable"` in host
status and assert zero media frames/work in closure tests.

Rollback is this documentation layer only. The next implemented layer is PR 16;
PR 15 is intentionally absent under the omission rule in the Lane D brief.

