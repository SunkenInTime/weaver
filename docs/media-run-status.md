# Media v2 unattended run status

Last updated: 2026-07-25

## Stack map

| Layer | Branch | Parent | State |
|---|---|---|---|
| 01/05 | `media/01-status-sourceapp` | `master` (`b1199b5`) | DRAFT PR #32 (`2feb700`) |
| 02/05 | `media/02-album-art` | layer 01 | IN PROGRESS |
| 03/05 | `media/03-transport` | layer 02 | NOT STARTED |
| 04/05 | `media/04-macos-adapter` | layer 03 | SPIKE-GATED / NOT STARTED |
| 05/05 | `media/05-noro-gate` | layer 04 if proven, otherwise layer 03 | NOT STARTED |

The Native SDK submodule remains at `3f6a68b606e110087b5992cbe75f700051f1b7f3`.
This run will not change the submodule pointer.

## Completed gates

- Required implementation brief, contracts, ADRs, roadmap, API orders, and
  styling autonomy/visual-gate brief read in full.
- Virgin `master` verified at `b1199b5f6cc3a09536c448a43d1a0cc1d3e59c39`.
- `npm test`: PASS, 62/62 tests.
- `npm run typecheck`: PASS.
- `runtime`: `zig build -Dweb-layer=exclude -Dtrace=off`: PASS with Zig 0.16.0.
- `host`: `zig build`: PASS with Zig 0.16.0.
- Layer 01 `npm test`: PASS, 62/62 tests.
- Layer 01 `npm run typecheck`: PASS.
- Layer 01 `runtime`: `zig build test -Dweb-layer=exclude -Dtrace=off`: PASS.
- Layer 01 `host`: `zig build test`: PASS.
- Layer 01 example: `weaver check examples/now-playing`: PASS.
- Layer 01 live Spotify check: paused and playing states observed on the next
  provider poll; live title, artist, source ID, and timeline rendered.
- Layer 01 visual gate: PASS. Viewed captures and per-element checklist are in
  `docs/media-evidence/pr01-visual.md`.
- Layer 02 recovered-work verification: host `zig build test` and runtime
  `zig build test -Dweb-layer=exclude -Dtrace=off`: PASS after the unattended
  session was resumed.
- Layer 02 SDK/example gates: `npm test` PASS 62/62, `npm run typecheck` PASS,
  `weaver check examples/now-playing` PASS.
- Layer 02 production builds: host `zig build` PASS; runtime
  `zig build -Dweb-layer=exclude -Dtrace=off` PASS.
- Layer 02 live/visual gate: PASS after repairing the observed 300×300
  `ImageTooLarge` failure with bounded host-side normalization. Viewed settled,
  track-change, and pause captures plus per-element results are in
  `docs/media-evidence/pr02-visual.md`.

## Blockers and unverified gates

- None for the Windows stack.
- PR 04 remains spike-gated. This Windows run cannot claim the required real
  macOS metadata frame or delivered command without recorded external Mac/CI
  execution evidence.

## Current work

Layer 02 implementation is in progress. The host now consumes coalesced SMTC
events, publishes bounded artwork through the host-owned hash cache, and emits
optional `artPath`; the runtime has canonical art-root containment and dynamic
same-ID image re-registration. Automated and live visual gates pass; the
required static-image parent/head idle A/B is active.

## Next executable task

Measure parent/head idle CPU and private memory with the identical
`examples/styling-images` widget, then finalize the layer-02 draft PR.
