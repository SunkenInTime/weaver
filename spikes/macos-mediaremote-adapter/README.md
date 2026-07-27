# macOS MediaRemote adapter gate

This spike records the layer-04 gate from `docs/media-v2-brief.md`. The
attended-Mac execution gate passed on 2026-07-25; the full report is
`docs/media-evidence/pr04-mac-spike.md`.

Run the static half on macOS after building the host:

```sh
spikes/macos-mediaremote-adapter/static-audit.sh
```

The audit reports:

- whether the installed public SDK exposes any MediaRemote declaration;
- any executable files present beneath the installed system private framework,
  with their code-signing identity when `codesign` can read it;
- whether the built Weaver host links MediaRemote or imports a symbol whose
  name contains `MediaRemote`;
- the exact vendored script hash, upstream commit marker, framework signature,
  license, and absence of Homebrew paths in the production adapter;
- the recorded execution gate and the separate, honest
  `UNVERIFIED_NEEDS_ATTENDED_MAC` state for Weaver's implementation.

Inventorying a private Apple-signed executable was not an invocation contract.
The attended run recorded all of the following together:

1. the exact Apple-signed executable or service invoked;
2. the exact invocation and bidirectional IPC protocol;
3. the source and redistribution status of every declaration/symbol used;
4. entitlement behavior at Weaver's macOS 15.4 floor;
5. signing, notarization, and redistribution implications;
6. lifecycle, crash detection, and reconnect behavior;
7. one real system-player metadata frame;
8. one command visibly delivered to that player.

Compile-only and static inventory still do not prove Weaver's implementation
produces frames or delivers commands. That live matrix remains
`UNVERIFIED (needs attended Mac)`.
