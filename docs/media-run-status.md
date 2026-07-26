# Media v2 unattended run status

Last updated: 2026-07-25

## Stack map

| Layer | Branch | Parent | State |
|---|---|---|---|
| 01/05 | `media/01-status-sourceapp` | `master` (`b1199b5`) | DRAFT PR #32 (`2feb700`) |
| 02/05 | `media/02-album-art` | layer 01 | DRAFT PR #33 (`f6a6442`) |
| 03/05 | `media/03-transport` | layer 02 | DRAFT PR #34; adversarial repair in progress |
| 04/05 | `media/04-macos-adapter` | layer 03 | DRAFT PR #36; restack pending |
| 05/05 | `media/05-noro-gate` | layer 04 | DRAFT PR #35; restack pending |

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
- Layer 02 static-image ReleaseFast A/B: PASS. Parent and layer 02 each used
  0.000 ms process CPU over matched ~60.014 s windows after 41–42 s settles.
  Private memory ended at 42.684 MiB parent / 41.570 MiB layer 02. Raw values
  and the bounded claim are recorded with the visual evidence.
- Adversarial finding F9 repaired at its owning layer: transient thumbnail
  refresh, normalization, size, and cache-publication failures retain the
  prior art path and cache pin. Only a successful replacement or a confirmed
  no-art state changes the snapshot. The new retention/no-art test and
  `host: zig build test` pass.

- Layer 03 focused SDK/CLI tests: PASS after fixing two recovered-work
  integration defects (missing SDK export and a misplaced test fixture).
- Layer 03 `npm test`: PASS, 63/63 tests.
- Layer 03 `npm run typecheck`: PASS.
- Layer 03 `runtime`: `zig build test -Dweb-layer=exclude -Dtrace=off`: PASS.
  A capability-wall test forces the conditional native bridge path to compile
  and proves undeclared runtimes receive no `native.mediaCommand`.
- Layer 03 `host`: `zig build test`: PASS.
- Layer 03 production builds: runtime and host PASS.
- Layer 03 example: `weaver check examples/now-playing`: PASS.
- Layer 03 live gate exposed and repaired a Windows synchronous-duplex
  deadlock. Both Windows endpoints now use overlapped I/O while preserving the
  dedicated blocking reader and sole-host-writer contract. Runtime and host
  Zig test/build gates pass after the repair.
- Layer 03 real Spotify verbs: PASS. Play, pause, next, previous, and seek all
  resolved `true`; titles changed for next/previous, and seek reached 129 s
  for a 128 s target.
- Layer 03 visual gate: PASS. Viewed captures and the per-element checklist
  are in `docs/media-evidence/pr03-visual.md`.
- Layer 03 adversarial repair gate: `npm test` PASS 63/63,
  `npm run typecheck` PASS, every example directory with `widget.tsx` passed
  `weaver check`, runtime `zig build test -Dweb-layer=exclude -Dtrace=off`
  PASS, and host `zig build test` PASS. Direct semantic macOS compilation
  passed for both `host/src/macos_host.zig` and
  `runtime/src/provider_macos.zig`.
- Layer 03 adversarial tests now cover a real mismatched-PID pipe rejection,
  macOS peer-PID rejection, command and acknowledgement EOF residuals,
  hostile command bursts, late-ack rollover, an exact 3000 ms deadline,
  transport-only idle-zero, forced SDK resolution despite a hostile widget
  tsconfig, and local hook aliases.

## Blockers and unverified gates

- None for the Windows stack.
- PR 04 remains spike-gated. This Windows run cannot claim the required real
  macOS metadata frame or delivered command without recorded external Mac/CI
  execution evidence.

## Current work

The 15-finding adversarial remediation is in progress bottom-up. F9 is fixed,
tested, committed, and pushed in layer 02. Layer 03 now contains the owning
repairs for F1/F2/F3/F4/F10/F11/F12: PID-bound endpoints, strict EOF framing,
reader wakeups and exact one-shot deadlines, keyed acknowledgements and a
provably bounded nack lane, forced SDK symbol resolution, deadline-bounded
endpoint writes, and an isolated deadline-bounded Windows command worker.
macOS reader and endpoint changes pass semantic cross-compilation; the full
layer gate passes.

## Next executable task

Commit/push the layer-03 remediation, then restack layer 04 and repair
F2/F5/F6/F7/F8/F11/F13/F14/F15.
