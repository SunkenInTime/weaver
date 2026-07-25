# Media PR 04 macOS adapter spike: BLOCKED

Date: 2026-07-25

Decision: **BLOCKED — no PR 04 implementation or draft PR is opened.**

The binding gate requires a real system-player metadata frame and a visibly
delivered command with recorded macOS evidence. This run is on Windows and no
new attended-Mac result was supplied. Compile-only or static claims cannot
substitute for either execution result.

## Evidence available

The existing attended-Mac public API spike was recorded on 2026-07-15 in
`docs/macos-m11-results.md` and `docs/macos-m11-data.json`:

- an `MPNowPlayingInfoCenter` publisher read back its own title and state;
- a concurrent observer process saw no Now Playing dictionary;
- the macOS 15 SDK rejected
  `MPMusicPlayerController.systemMusicPlayer` as unavailable on macOS;
- no production binary linked or dynamically loaded MediaRemote.

That evidence remains valid for rejecting the public publication APIs, but it
does not identify a supported private bridge and does not satisfy the new
adapter gate.

`spikes/macos-mediaremote-adapter/static-audit.sh` adds the reproducible static
half for macOS CI. It inventories public-SDK paths, executable candidates
beneath the installed private framework and their readable signing identity,
then proves the built Weaver host has no MediaRemote dependency or undefined
symbol. It explicitly emits:

```json
{
  "executionGate": {
    "realMetadataFrame": false,
    "deliveredCommand": false,
    "status": "BLOCKED"
  }
}
```

## Required questions and current result

| Required spike output | Result |
|---|---|
| Exact Apple-signed executable/service invoked | Not established. Static candidate inventory is not invocation evidence. |
| Invocation and bidirectional IPC protocol | Not established. No private helper was invoked. |
| Declaration/symbol source | No MediaRemote declaration exists in the public SDK surface used by the existing probe; no private declaration was copied. |
| Entitlement behavior at macOS 15.4 floor | Not executed; unverified. |
| Signing/notarization/redistribution implications | No distributable private-API contract established; unverified. |
| Lifecycle, crash detection, reconnect | Cannot be specified without a proven helper/protocol. |
| Real metadata frame | **FAIL / absent.** |
| Delivered command | **FAIL / absent.** |

The narrow outcome is to retain ADR 0015 and layer 03's honest macOS behavior:
the duplex channel exists, but declared valid transport commands resolve
`false`; no fabricated media frame is emitted. Layer 05 proceeds from layer 03
and completes the Windows slice. A future attended-Mac spike may resume layer
04 only by producing all required execution evidence.
