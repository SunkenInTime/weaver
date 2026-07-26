# Media v2 unattended run status

Last updated: 2026-07-26

## Stack map

| Layer | Branch | Parent | State |
|---|---|---|---|
| 01/05 | `media/01-status-sourceapp` | `master` (`b1199b5`) | DRAFT PR #32 (`4dcf19c`) |
| 02/05 | `media/02-album-art` | layer 01 | DRAFT PR #33 (`e8748fb`) |
| 03/05 | `media/03-transport` | layer 02 | DRAFT PR #34 (`d3753b2`); restacked on the final layer-02 repair |
| 04/05 | `media/04-macos-adapter` | layer 03 | DRAFT PR #36; round-3 repair locally green |
| 05/05 | `media/05-noro-gate` | layer 04 | DRAFT PR #35; restack in progress, Dara's REC-dot commit preserved |

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
- Layer 04 adversarial local gate: `npm test` PASS 63/63,
  `npm run typecheck` PASS, release audit PASS, every example directory with
  `widget.tsx` passed `weaver check`, runtime test/build PASS, and Windows host
  test/build PASS. Direct no-emit aarch64-macos semantic compiles of
  `providers_macos.zig` and `macos_host.zig` PASS. These semantic compiles do
  not compile/link the new Objective-C image normalizer and do not substitute
  for macOS CI or attended execution.
- Layer 04 adversarial tests cover adapter EOF residuals, blank-title
  sessions, unknown playback state, timestamp-aware 1 Hz advancement, a real
  300×300 PNG normalization fixture, malformed artwork, helper failure
  rejection, exit-2 decline, no-session seek decline, 30-second restart
  stability, and the 15.4 floor predicate.
- Layer 04 round-2 local gate: `npm test` PASS 63/63,
  `npm run typecheck` PASS, every example with `widget.tsx` passed
  `weaver check`, runtime and Windows-host `zig build test` PASS, and direct
  no-emit aarch64-macos compiles of `providers_macos.zig` and
  `macos_host.zig` PASS. New tests cover the 10-second first-frame boundary,
  invalid/non-1× playback rate and 1 Hz advancement, plus a helper-owned
  verifier executable for delayed seek convergence, no session, callback
  timeout, and persistent out-of-tolerance observations. The Objective-C
  helper build/test and hosted session remain CI-pending.
- Layer 04 round-3 local gate: `npm test` PASS 63/63,
  `npm run typecheck` PASS, release audit PASS, all 18 examples passed
  `weaver check`, runtime build/test PASS (including the automation build),
  and Windows host build/test PASS. macOS-only compilation and execution are
  pending the hosted runner.
- Round 3 removes the adapter's post-first-frame 100 ms poll: after one valid
  frame the worker now waits indefinitely for stdout/HUP, and a regression
  test asserts that monotonic time cannot create idle wakeups. A
  runtime-detected macOS command-send failure is now process-fatal; the hosted
  automation test requires a new widget PID, a new randomized endpoint,
  resumed media frames, and a subsequently resolved transport command.
- Layer 05 adversarial Windows live art check: PASS. A real Next transition
  retained the prior cover at 250/750/1250 ms and showed a visibly different
  replacement cover/title at 2000 ms. All five exact-region PNGs were opened
  and viewed; no bundled fallback, blank image, or black flash appeared.
- Layer 05 exact timeout live check: PASS. With the provider connection open
  and weaverd deliberately suspended, the temporary transport-only diagnostic
  was visibly pending at 1000 ms and rejected at 3300 ms. The runtime log
  measured `TIMEOUT_REJECTED_3003MS`. weaverd was resumed and the diagnostic
  was uninstalled/deleted. Evidence is in
  `docs/media-evidence/pr05-adversarial-live.txt` and `pr05-visual.md`.
- Layer 05 final automated gate: `npm test` PASS 63/63,
  `npm run typecheck` PASS, release audit PASS, all 18 widget examples passed
  `weaver check`, runtime test/build PASS, Windows host test/build PASS, and
  both macOS provider/host no-emit semantic compiles PASS.
- After the final layer-03 macOS test-harness repair and 04/05 restack, the
  layer-05 head was rechecked locally: `npm test` PASS 63/63,
  `npm run typecheck` PASS, all 18 widget examples passed `weaver check`,
  runtime `zig build test -Dweb-layer=exclude -Dtrace=off` PASS, and host
  `zig build test` PASS.
- A post-restack Greptile P1 correctly identified that macOS slot teardown
  still joined an in-flight command worker on the supervision loop. Layer 04
  now transfers ownership to the stopped worker, which self-releases after
  the helper's bounded timeout; final process shutdown tracks and drains all
  workers within an explicit three-second fail-closed window. A deterministic
  test holds a command for 300 ms and requires supervision-side teardown to
  return in under 100 ms. Both macOS source files pass direct aarch64 semantic
  compilation; runtime behavior remains attended-Mac unverified.
- The first layer-03 hosted-session run and its retry deterministically
  exposed a time-only macOS startup crash: `subscribe: ["time"]` incorrectly
  armed the host-provider drain, which reached an inert client whose clock had
  not been initialized. Layer 03 now excludes runtime-native `time` from
  host-backed subscription polling and initializes the inert client's clock.
  The repaired hosted run passed that Clock startup gate.
- That same hosted run then exposed frame wakes bypassing the established
  timer drain: all system frames arrived, but immediate one-at-a-time drains
  broke the two-widget fan-out batch gate. Layer 03 now advances the reader
  wake generation only for acknowledgements and acknowledgement-protocol
  failures; metadata frames retain their 1 Hz/fast-audio timer drain.
  Runtime tests and direct aarch64 semantic compilation pass; the final
  hosted-session result is pending.

## Blockers and unverified gates

- None for the Windows stack.
- The attended route spike is PASSED per
  `docs/media-evidence/pr04-mac-spike.md`; it does not prove the remediated
  Weaver implementation.
- The remediated macOS implementation remains **UNVERIFIED (needs attended
  Mac)** for: real metadata and 1 Hz timeline advancement; 300×300+ art and
  malformed-art loss/recovery; all five verbs and ±2000 ms verified seek;
  no-session seek false; helper/framework/timeout/signal rejection; residual
  EOF, crash, quit/relaunch, exponential backoff, and TERM-to-KILL teardown;
  Developer-ID signing, timestamp, notarization, quarantine, and Gatekeeper.
- Exact macOS 15.4-floor execution is separately **UNVERIFIED (needs attended
  Mac running 15.4)**. The runtime ProcessInfo gate is implemented and tested
  statically; no helper is spawned below the floor.

## Current work

The 15-finding adversarial remediation is implemented through layer 05:

| Finding | Owning layer | Accepted state |
|---|---|---|
| F1 | 03 | Fixed: both endpoints require the launched child PID; real hijack tests added. |
| F2 | 03/04 | Fixed: all command, runtime, and adapter readers discard/count EOF residuals. |
| F3 | 03 | Fixed: host-backed subscription-only polling (time excluded), reader wake, exact one-shot 3 s deadline. |
| F4 | 03 | Fixed: nine-entry proven nack lane plus keyed four-pending ack slots and late-ack test. |
| F5 | 04 | Fixed: helper/channel failures reject; only exit 2 OS decline resolves false. |
| F6 | 04 | Fixed: seek requires bounded read-back within ±2000 ms accounting for advance. |
| F7 | 04 | Fixed: blank title is a session, unknown is stopped, timestamped position advances at 1 Hz. |
| F8 | 04 | Fixed: decode/downsample/PNG/cache path; malformed art causes adapter loss. |
| F9 | 02 | Fixed: failed refresh retains the prior Windows art snapshot and pin. |
| F10 | 03 | Fixed: forced SDK mapping and alias/re-export symbol tracing with bypass tests. |
| F11 | 03/04 | Fixed: bounded endpoint writes and bounded TERM-to-KILL helper teardown. |
| F12 | 03/04 | Fixed: platform calls run on bounded per-widget workers; macOS slot teardown never joins them on supervision. |
| F13 | 04 | Fixed: restart reset requires a frame plus 30 s stable streaming. |
| F14 | 04 | Fixed: ProcessInfo 15.4 runtime gate; exact-floor behavior remains unverified. |
| F15 | 04/05 | Fixed: static audit, blocked record, spike row, results, and run status now tell the same dated story. |

| Round-3 item | Owning layer | Accepted state |
|---|---|---|
| post-frame idle work | 04 | Fixed locally: startup alone uses bounded watchdog polls; a proven stream blocks indefinitely on stdout/HUP. Hosted macOS result pending. |
| runtime-detected send failure | 04 | Fixed locally: failure marks the channel fatal and wakes/exits the runtime through crash supervision. The hosted full PID/endpoint/frame/command recovery gate is pending. |
| stale result narrative | 05 | Pending layer-05 restack; the CI-pending statement will be replaced only with actual completed check results. |

## Next executable task

Finish and push the layer-05 restack without dropping Dara's REC-dot change,
then wait for and record every actual Actions result. In particular, hosted
macOS must compile/link the helper and pass the full runtime-fatal recovery
gate before this document calls that behavior remotely verified.
