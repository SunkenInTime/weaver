# macOS MediaRemote adapter gate

This spike records the layer-04 gate from `docs/media-v2-brief.md`. It does not
link, load, invoke, or copy declarations from Apple's private MediaRemote
framework.

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
- the two execution gates, `realMetadataFrame` and `deliveredCommand`, as
  `false`.

Inventorying a private Apple-signed executable is not an invocation contract.
The spike remains blocked until an attended Mac run records all of the
following together:

1. the exact Apple-signed executable or service invoked;
2. the exact invocation and bidirectional IPC protocol;
3. the source and redistribution status of every declaration/symbol used;
4. entitlement behavior at Weaver's macOS 15.4 floor;
5. signing, notarization, and redistribution implications;
6. lifecycle, crash detection, and reconnect behavior;
7. one real system-player metadata frame;
8. one command visibly delivered to that player.

Compile-only, framework-presence, symbol-inventory, and application-local
`MPNowPlayingInfoCenter` results do not satisfy items 7 or 8.
