# macOS v0 reports media unavailable rather than use a private system-player API

Weaver will not ship a macOS media provider in v0. At the final macOS 14.2
floor, no public distributable API gives a background host system-wide access
to another application's Now Playing metadata, playback state, position,
artwork, and controls. PR 15 is therefore omitted. macOS treats `media` as an
unavailable Provider: it emits no fabricated empty or stopped frame, starts no
poller, and makes no claim that silence means “nothing is playing.” The public
Widget source and existing cross-platform provider shape remain unchanged.

The supported macOS v0 field and action set is deliberately empty:

| Capability | Existing portable surface | macOS v0 |
|---|---|---|
| Title, artist, album | `media` frame | Unavailable |
| Playing state | `media` frame | Unavailable |
| Position and duration | `media` frame; position advances at 1 Hz on Windows | Unavailable |
| Artwork | Not in the frozen `media` frame | Not added |
| Play, pause, seek, next, previous | Deliberately outside the current contract | Not added |

Windows continues to implement the existing fields through the public
`GlobalSystemMediaTransportControlsSessionManager`. This decision does not
weaken or reshape that provider, add a platform flag, expose a player bundle ID,
or pull media control into Lane D.

[`MPNowPlayingInfoCenter`](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)
is a publication interface for media an application plays. Its installed SDK
header says the default center holds information about the current application
and that the application must set its playback state. The M11 probe makes that
boundary executable: one process can set and read back all existing Weaver
fields, while a concurrent process sees no Now Playing dictionary. Availability
of the class therefore does not establish observation of the system's active
player. `MPRemoteCommandCenter` has the same direction: an application
registers handlers for commands sent to its own playback session.

`MPMusicPlayerController.systemMusicPlayer` is not a macOS escape hatch. The
macOS 15 public SDK marks the controller unavailable on macOS, and the negative
M11 compile probe must fail for a 14.2 deployment target. MusicKit and media
library access concern Apple Music catalog/library content and playback chosen
by Weaver; they do not observe arbitrary players. Apple's newer
[`Now Playing` framework](https://developer.apple.com/documentation/nowplaying)
also publishes an application's sessions to system UI, is currently documented
as beta, is absent from the installed macOS 15 SDK, and cannot satisfy a 14.2
shipping floor or reverse the data direction.

Apple Events are rejected as the v0 provider architecture. Music and Spotify
offer useful but different scripting dictionaries; QuickTime exposes document
time semantics; the installed Podcasts application exposes no dictionary; and
Safari exposes no common playback session. Supporting them would require an
adapter and polling contract per player, miss unscriptable players and browser
media, and prompt separately for control of other applications. Apple requires
an [`NSAppleEventsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)
when sending Apple events, and hardened distribution requires the
[`com.apple.security.automation.apple-events`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)
entitlement to request that access. This is a possible future opt-in
player-integration product, not honest system-wide parity.

The installed `/System/Library/PrivateFrameworks/MediaRemote.framework` is the
tempting system-global route. It is rejected because it is private: Weaver will
not link it, dynamically resolve its symbols, copy declarations from reverse-
engineered headers, or make distribution depend on an undocumented daemon
protocol. Accessibility/UI scraping, notification scraping, process memory,
and database/container inspection are rejected for the same stability,
privacy, coverage, and distribution reasons.

Unavailable has zero media cadence: no 1 Hz position timer, metadata polling,
artwork fetch, automation prompt, or player observer. A macOS subscriber gets
no media frames and retains its normal no-data UI. Host diagnostics report
`mediaAvailability: "unavailable"`; PR 16 owns adding that explicit status to
the already frame-silent macOS host and proving the provider remains idle. A
future public API can replace this decision behind the same host/provider seam,
but only after a new ADR demonstrates system-wide observation, player coverage,
permissions, distribution eligibility, cadence, cost, and loss behavior at the
supported floor.

The rollback boundary is documentation and the explicit unavailable status.
There is no production adapter or private dependency to unwind. The next
stacked layer is PR 16's CI, regression, diagnostics, and release closure.

