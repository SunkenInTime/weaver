# Media PR 04 attended-Mac adapter spike

Date: 2026-07-25

Decision: **PASS — the layer-04 execution gate is satisfied.**

The current `ungive/mediaremote-adapter` technique produced real system-wide
Spotify metadata and delivered a pause command on this M2 Mac running macOS
26.5.1. The production adapter is deliberately not implemented here. This
branch contains only the evidence required to unblock layer 04.

Raw terminal evidence is in
[`pr04-live-session.txt`](pr04-live-session.txt). The reproducible Weaver
static audit is in [`pr04-static-audit.json`](pr04-static-audit.json).

## Hard execution gates

### Real system-player metadata frame: PASS

The exact Apple-signed process invocation was:

```text
/usr/bin/perl /opt/homebrew/Cellar/media-control/0.7.6/lib/media-control/mediaremote-adapter.pl /opt/homebrew/Cellar/media-control/0.7.6/Frameworks/MediaRemoteAdapter.framework /opt/homebrew/Cellar/media-control/0.7.6/lib/media-control/MediaRemoteAdapterTestClient get --now --no-artwork
```

It returned a frame from Spotify, PID 7472:

```json
{"playbackRate":1,"album":"Tweaker Poem","mediaType":"kMRMediaRemoteNowPlayingInfoTypeAudio","elapsedTimeNow":51.227281843185423,"trackNumber":1,"elapsedTime":0.085999999999999993,"timestamp":"2026-07-25T19:50:04Z","bundleIdentifier":"com.spotify.client","processIdentifier":7472,"title":"Satellites","totalDiscCount":1,"totalTrackCount":0,"duration":211,"artist":"Frost Children","contentItemIdentifier":"B2FE397C-C926-4282-BDF2-358681FB4FF9","playing":true}
```

[`pr04-spotify-playing.png`](pr04-spotify-playing.png) shows the matching
Spotify track, artist, album, advancing position, and visible pause controls.

### Visibly delivered command: PASS

The pause was delivered through MediaRemote, not AppleScript:

```text
/usr/bin/perl /opt/homebrew/Cellar/media-control/0.7.6/lib/media-control/mediaremote-adapter.pl /opt/homebrew/Cellar/media-control/0.7.6/Frameworks/MediaRemoteAdapter.framework /opt/homebrew/Cellar/media-control/0.7.6/lib/media-control/MediaRemoteAdapterTestClient send 1
```

The command exited 0. The next settled MediaRemote frame contained
`"playing":false`; Spotify's independent scripting state was `paused` at the
same 51.338-second position. The immediate read after command completion was
still stale (`playing:true`), so the production adapter must treat command
success as delivery, not as proof that a subsequent observation has already
settled.

[`pr04-spotify-paused.png`](pr04-spotify-paused.png) shows the same track at
0:51 with play controls visible.

## Required spike outputs

| Required output | Result | Evidence |
|---|---|---|
| Exact Apple-signed executable/service invoked | **PASS** | `/usr/bin/perl`; running PID 24501 had `Identifier=com.apple.perl`, `Platform identifier=26`, Apple signing authorities, and designated requirement `anchor apple`. `vmmap` showed both the custom adapter and system MediaRemote mapped into that process. |
| Invocation and bidirectional IPC protocol | **PASS** | Metadata uses a persistent helper whose stdout is newline-delimited `{"type":"data","diff":bool,"payload":object}` JSON. There is no stdin command protocol. Controls are separate short-lived `/usr/bin/perl ... send ID` or `seek POSITION` processes; success is empty stdout plus exit 0, failure is stderr plus nonzero exit. |
| Declaration/symbol source | **PASS** | All private declarations and string symbol names come from `ungive/mediaremote-adapter` v0.7.6 (`src/private/MediaRemote.h` and `.m`, adapter commit `3ac3d4b`), licensed BSD-3-Clause. The helper resolves system symbols at runtime with `CFBundleGetFunctionPointerForName`; the system MediaRemote binary is not copied or shipped. |
| Entitlement behavior at the macOS 15.4 floor | **UNVERIFIED (needs attended Mac at 15.4)** | The route worked on installed macOS 26.5.1: `adapter ... test` exited 0, and `codesign` exposed the Apple platform signature plus `com.apple.perl` identity without an explicit entitlement dictionary. That does not prove execution on 15.4. Weaver now enforces a ProcessInfo runtime floor and exact-floor behavior still requires an attended 15.4 run. |
| Signing, notarization, redistribution implications | **PASS** | The adapter source/binary redistribution grant is BSD-3-Clause. The Homebrew framework is ad-hoc signed, which is not a shipping signature. A direct Weaver distribution must Developer-ID sign the helper framework/test binary with hardened runtime, notarize the complete app, and rerun this gate from a quarantined build. Mac App Store distribution is not viable because App Review Guideline 2.5.1 permits only public APIs. |
| Lifecycle, crash detection, reconnect | **PASS** | On Spotify quit the live helper emitted `playing:false`, then `{}`, then selected the paused Music session; with both players gone it emitted `{}`. It survived Spotify relaunch and emitted a new full frame. SIGTERM produced clean EOF/exit 0. Relaunch emitted `{}` followed by the current full frame. Weaver must detect EOF/exit, publish its canonical empty frame once, restart with bounded backoff, and rebuild state from the next non-diff frame. |
| Real metadata frame | **PASS** | Spotify `Satellites` / `Frost Children` / `Tweaker Poem`, `playing:true`, observed system-wide. |
| Delivered command | **PASS** | `send 1` exited 0; Spotify and the next MediaRemote frame both showed paused; before/after screenshots match. |

## Protocol finding that changes the implementation shape

The upstream adapter is not one bidirectional stdio child. The obvious Weaver
boundary is therefore:

1. supervise one long-lived `stream --no-diff --no-artwork` process for
   newline-delimited metadata;
2. launch a bounded short-lived command process for each transport request;
3. translate command exit 0/nonzero into Weaver's existing boolean ack;
4. treat stream EOF, malformed JSON, or child exit as adapter loss, emit the
   canonical empty media frame once, and reconnect with bounded backoff.

Do not invent stdin framing that the upstream helper does not implement.

Artwork should be enabled only after the adapter boundary can decode and
atomically cache the optional base64 `artworkData`; the successful metadata
and control spike used `--no-artwork` to keep the protocol evidence narrow.

## Distribution boundary

The v0.7.6 helper framework directly names and resolves private MediaRemote
symbols. That is an explicit App Store blocker, regardless of the indirection
through `/usr/bin/perl`. For direct Developer ID distribution, Apple requires
distributed executable code to carry a valid Developer ID signature, hardened
runtime, and a secure timestamp before notarization. The current Homebrew
artifact is useful execution prior art, not proof that Weaver's final app
bundle passes notarization or Gatekeeper.

Before layer 04 is called shippable, test a real Weaver `.app` that bundles the
script and helper code, signs every executable artifact, notarizes and staples
the package, then executes this same frame/control/lifecycle matrix after
download quarantine. Failure routes to the already-approved per-app scripting
fallback without changing the widget contract.

References:

- Upstream adapter and BSD-3-Clause source:
  <https://github.com/ungive/mediaremote-adapter/tree/3ac3d4bdf862c7b5399b4fba4df5689f5c38609a>
- Apple App Review Guidelines 2.5.1:
  <https://developer.apple.com/app-store/review/guidelines/#software-requirements>
- Apple notarization requirements:
  <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- Apple distribution-signing guidance:
  <https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/>
