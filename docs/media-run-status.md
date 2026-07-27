# Media v2 unattended run status

Last updated: 2026-07-27

## Stack map

| Layer | Branch | Parent | State |
|---|---|---|---|
| 01/05 | `media/01-status-sourceapp` | `master` (`b1199b5`) | DRAFT PR #32 (`4dcf19c`) |
| 02/05 | `media/02-album-art` | layer 01 | DRAFT PR #33 (`e8748fb`) |
| 03/05 | `media/03-transport` | layer 02 | DRAFT PR #34 (`7da433e`) |
| 04/05 | `media/04-macos-adapter` | layer 03 | DRAFT PR #36 (`ddcbc9e`) |
| 05/05 | `media/05-noro-gate` | layer 04 | DRAFT PR #35; final implementation/evidence head `cdff961`, Dara's REC-dot commit preserved |

The Native SDK submodule remains at `3f6a68b606e110087b5992cbe75f700051f1b7f3`.
This run will not change the submodule pointer.

## Attended Mac verification and live-only fold (2026-07-26)

The attended M2/macOS 26.5.1 run is **PASS WITH ONE REMAINING ATTENDED
GAP**. The full report and viewed captures are in
`docs/media-evidence/pr05-mac-verify.md`. Real Spotify/Music/QuickTime checks
passed metadata/artwork, pause/play/next/previous, honest seek and no-session
false, helper kill/backoff/recovery, player quit/relaunch, 65-second
idle-zero, Noro pixels/controls, channel recovery, drag, and persisted
geometry. The only attended product check not run was a session reporting
`playbackRate: 2`; that path remains unit-covered but attended-unverified.

Four live-only defects found during that run are folded at their owning
layers with attribution to evidence commit `72d04c2`:

- layer 03 uses `posix.read` for short persistent UDS commands/acks and gives
  accepted-socket closure to the reader after shutdown-before-join;
- layer 04 uses `poll(2)` plus `posix.read` for short adapter frames and feeds
  provider supervision from the same Zig awake-clock domain as the worker;
- layer 05 adds a transparent 312x12 seek target without changing the visible
  312x3 strip.

The Windows Noro fold gate is also PASS. A paused pre-fix/fixed A/B produced
two exact 340x356 captures with the same SHA-256 and zero differing pixels.
A real pointer click on the enlarged layer visibly sought the paused Spotify
track from `01:40` to `02:33`. Captures and the per-element checklist are in
`docs/media-evidence/pr05-visual.md`.

The clean fold CI exposed one hosted-only follow-up without invalidating the
attended behavior: the command/ack UDS descriptors are nonblocking, so a bare
second `posix.read` could misclassify the normal between-frame `EAGAIN` as
channel loss. Layer 03 now blocks in `poll(2)` before every short UDS read and
tests two commands and two acknowledgements separated by idle time. The
hosted recovery seam also observes the successful post-restart callback
directly instead of racing an unrelated debounced `useStorage` write after
the product contract (new PID, fresh endpoint, resumed frame, successful
subsequent command) has already passed. The attended report remains the
ground truth for sustained live recovery.

## Final acknowledgement backpressure repair (2026-07-27)

Greptile's final PR #36 P1 was valid: macOS acknowledgement writes could
retry for one second per backpressured widget on the shared supervision loop.
Owning-layer commit `7da433e` replaces that loop with exactly one
`send(MSG_DONTWAIT | MSG_NOSIGNAL)`. A partial write, EAGAIN, or other error
marks the per-widget endpoint stopping before shutdown and returns failure
into the existing channel-failure/crash-restart path. No retry, sleep, or new
delivery mechanism runs on the loop.

The regression forces the exact production send primitive's backpressure
result at compile time and proves the next unrelated widget supervision turn
occurs within 100 ms. This avoids depending on platform socket-buffer sizing
while still pinning the nonblocking control flow. An earlier real-buffer
fixture exposed an accept-thread teardown race during CI; the accepted
production fix (mark stopping before shutdown) remains, while the
OS-dependent fixture was replaced by the deterministic seam.

All five exact implementation heads passed a fresh complete Actions wave,
including hosted Apple-silicon sessions. Greptile re-reviewed PR #36 head
`ddcbc9e` at **5/5**, said it appears safe to merge, and reported no P1s.

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
- Layer 03 round-2 gate: `npm test` PASS 63/63, `npm run typecheck` PASS,
  runtime and host `zig build test` PASS, and
  `weaver check examples/now-playing` PASS. Direct aarch64-macos no-emit
  compilation of the runtime provider passes. New tests cover a stalled
  connected Unix host, deterministic host/runtime cancel-before-read
  shutdown, fatal-channel crash/restart, and SDK calls through destructuring,
  deferred assignment, object properties, and a re-export chain.
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
  helper build/test and hosted session passed on the recorded round-2 heads;
  the new round-3 recovery scenario is awaiting its own hosted result.
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
  Runtime tests and direct aarch64 semantic compilation pass.
- Layer 05 round-2 local gate: `npm test` PASS 63/63,
  `npm run typecheck` PASS, all 18 examples passed `weaver check`, runtime and
  Windows-host `zig build test` PASS, and both macOS no-emit semantic compiles
  PASS. The Noro seek handler now uses normalized `event.u`; a viewed live
  Spotify recheck moved the visible position from `03:24` to `04:09` within
  2.2 seconds after a 75% strip press, with unchanged shell rendering.
- The final layer-03 stalled-send test uses a real connected UDS plus an
  injected retry seam in the production nonblocking send loop. It proves the
  deadline, disconnect, and return to the app loop without depending on
  kernel socket-buffer capacity. The final hosted run passes this test.
- The hosted fan-out gate now asserts semantic delivery: two running
  per-widget endpoints, two subscribers, and bounded successful frame writes.
  It does not mistake `SOCK_STREAM` read segmentation or log flush timing for
  a protocol packet boundary.
- The first-frame watchdog is also enforced from the host's 1 Hz supervision
  tick. Its atomic attempt state races the first valid frame against the exact
  10-second deadline; expiry kills the child, emits one canonical empty frame,
  marks unavailable, and enters the existing bounded backoff. Hosted runs
  `30189812372` and `30189813642` pass the full smoke.
- Greptile replies were posted for PR #35's normalized `event.u` fix and both
  PR #36 worker-stall fixes; their commit references were updated after the
  final restack.
- A final PR #33 re-review exposed one valid F9 edge: after an SMTC session
  replacement, a failed first thumbnail refresh could pair the retained prior
  cover with replacement metadata. Layer 02 now retains the cache snapshot and
  pin but withholds the replacement frame until its artwork publishes or
  no-art is confirmed. The focused regression test passes. A real Spotify Next
  transition was captured and every exact-region PNG was viewed: the complete
  old title/cover remained at 250 and 750 ms, and the replacement title/cover
  appeared together at 1500 ms with no blank or mismatched frame. Evidence and
  the per-element checklist are in `docs/media-evidence/pr05-visual.md`.
- The follow-up review correctly found that the initial atomic guard consumed
  a transient first-refresh dirty event without retrying. While
  `refresh_failed` remains active, the subscribed provider now retries on its
  existing bounded 1 Hz poll; it creates no transport-only or idle timer. The
  native retry truth-table regression test and every exact-head gate pass.
- The subsequent review correctly separated permanent failure from transient
  retry. An oversized thumbnail resolves immediately as unavailable; other
  unresolved refreshes retain the prior complete frame for three subscribed
  polls, then publish refreshed metadata explicitly without art while
  retaining the old cache path/pin. Later subscribed retries may still
  recover and publish art. Tests prove the retry bound and the unavailable
  frame state, so no permanent source can strand the prior media frame.
- Greptile's final PR #33 review is PASS on `a153e6c`.
- After that repair and the final restack, every changed layer was re-run
  locally. Layer 02: `npm test` PASS 62/62; layers 03-05: PASS 63/63. Every
  layer passed `npm run typecheck`, runtime and host `zig build test`, and all
  18 `weaver check` example gates.
- Final acknowledgement-backpressure gate: layer 03/04/05 local heads passed
  `npm test` 63/63, `npm run typecheck`, release audit, runtime
  `zig build test -Dweb-layer=exclude -Dtrace=off`, host `zig build test`,
  and all 18 `weaver check` examples. The macOS headless jobs executed the
  deterministic backpressure/supervision test on both architectures.

## Final implementation-head GitHub Actions results

All conclusions below are actual completed results for the named exact heads.
Each run passed the repository gate, Intel and Apple-silicon headless jobs,
and the hosted Apple-silicon session.

| PR | Head evidenced | Actions run | Jobs |
|---|---|---|---|
| #32 / 01 | `4dcf19c` | `30173553577` attempt 3 | PASS: all four jobs |
| #33 / 02 | `e8748fb` | `30211809074` attempt 3 | PASS: all four jobs |
| #34 / 03 | `7da433e` | `30300691042` | PASS: all four jobs |
| #36 / 04 | `ddcbc9e` | `30300703540` | PASS: all four jobs |
| #35 / 05 | `cdff961` | `30300706695` | PASS: all four jobs |

The layer-05 status-only commit that contains this table changes no
implementation or evidence. Its post-push exact-head CI result is recorded in
PR #35 because a commit cannot contain the run ID created by its own push.

## Superseded pre-attended blockers

This historical list is retained to show what the attended run closed. It is
superseded by the final blocker list immediately below.

- None for the Windows stack.
- The attended route spike is PASSED per
  `docs/media-evidence/pr04-mac-spike.md`; it does not prove the remediated
  Weaver implementation.
- The remediated macOS implementation remains **UNVERIFIED (needs attended
  Mac)** for: real metadata and playback-rate-aware 1 Hz advancement at
  non-1×; 300×300+ art and malformed-art loss/recovery; all five verbs,
  delayed seek convergence and ±2000 ms verified seek at non-1×; no-session
  seek false; helper/framework/timeout/signal rejection; a silent first-frame
  watchdog; fatal shared-channel widget restart with resumed frames and
  transport; residual EOF, crash, quit/relaunch, exponential backoff, and
  TERM-to-KILL teardown; Developer-ID signing, timestamp, notarization,
  quarantine, and Gatekeeper.
- Exact macOS 15.4-floor execution is separately **UNVERIFIED (needs attended
  Mac running 15.4)**. The runtime ProcessInfo gate is implemented and tested
  statically; no helper is spawned below the floor.

## Final blockers and unverified gates

- None for the Windows stack.
- The attended Mac implementation gate is PASSED per
  `docs/media-evidence/pr05-mac-verify.md`.
- The sole remaining attended product gap is a real session reporting
  `playbackRate: 2`; the rate parser, timeline advancement, and seek tolerance
  remain unit-covered, but the attended 2x check was **NOT RUN**.
- Exact macOS 15.4-floor execution is separately unverified. The runtime
  ProcessInfo gate is implemented and tested, but the attended machine ran
  macOS 26.5.1.
- Developer-ID signing, secure timestamp, notarization, quarantine, and
  Gatekeeper remain distribution gates, not unresolved attended media
  behavior. Mac App Store distribution remains unsupported by ADR 0017.

## Current work

The original 15-finding remediation remains implemented. Round 2 additionally
fixes the three partial/new P1s and four P2s through layer 05:

| Finding | Owning layer | Accepted state |
|---|---|---|
| F1 | 03 | Fixed: both endpoints require the launched child PID; real hijack tests added. |
| F2 | 03/04 | Fixed: all command, runtime, and adapter readers discard/count EOF residuals. |
| F3 | 03 | Fixed: host-backed subscription-only polling (time excluded), reader wake, exact one-shot 3 s deadline. |
| F4 | 03 | Fixed: nine-entry proven nack lane plus keyed four-pending ack slots and late-ack test. |
| F5 | 04 | Fixed: helper/channel failures reject; only exit 2 OS decline resolves false. |
| F6 | 04 | Fixed: seek polls to a two-second deadline and requires read-back within ±2000 ms at the reported rate. |
| F7 | 04 | Fixed: blank title is a session, unknown is stopped, and validated-rate position advances at 1 Hz. |
| F8 | 04 | Fixed: decode/downsample/PNG/cache path; malformed art causes adapter loss. |
| F9 | 02 | Fixed: transient failure retains the prior complete Windows frame and retries at the subscribed 1 Hz cadence; definite/exhausted failure publishes refreshed metadata artless without clearing the prior cache pin, so stale pairing and indefinite retention are both impossible. |
| F10 | 03 | Fixed: forced SDK mapping, binding/assignment tracing, and SDK-signature backstop with bypass tests. |
| F11 | 03/04 | Fixed: both UDS directions use bounded writes and helper teardown escalates TERM-to-KILL. |
| F12 | 03/04 | Fixed: platform calls run on bounded per-widget workers; macOS slot teardown never joins them on supervision. |
| F13 | 04 | Fixed: restart reset requires a frame plus 30 s stable streaming. |
| F14 | 04 | Fixed: ProcessInfo 15.4 runtime gate; exact-floor behavior remains unverified. |
| F15 | 04/05 | Fixed: static audit, blocked record, spike row, results, and run status now tell the same dated story. |

| Round-2 item | Owning layer | Accepted state |
|---|---|---|
| macOS runtime send | 03 | Fixed: nonblocking one-second deadline; the send-error path unregisters the pending slot and rejects. |
| Windows shutdown race | 03 | Fixed: persistent manual-reset shutdown events, stopping checks before every read, and deterministic barrier tests in both readers. |
| CLI binding bypasses | 03 | Fixed: binding/assignment tracing plus the resolved-signature declaration backstop and all four named bypass tests. |
| fatal shared channel | 03/04 | Fixed: both hosts kill and crash-restart the slot rather than strand it. |
| first-frame watchdog | 04 | Fixed: 10-second silent-helper kill, one loss frame, bounded backoff; hosted execution PASS. |
| seek convergence | 04 | Fixed: repeated observations through the two-second deadline with delayed/no-session/timeout/out-of-tolerance verifier tests. |
| playback rate | 04 | Fixed: parsed/validated and used in timestamp, synthetic advancement, and seek verification. |
| Noro normalized seek | 05 | Fixed: `event.u` replaces the hardcoded width division; live Windows recheck passed. |

| Round-3 item | Owning layer | Accepted state |
|---|---|---|
| post-frame idle work | 04 | PASS attended: after the first frame the worker blocks on stdout/HUP; the 65-second paused run measured heartbeat-scale work rather than 10 Hz wakeups. |
| runtime-detected send failure | 04 | PASS attended: channel recovery resumed transport without stranding the widget; synthetic crash-restart coverage remains in CI. |
| live short reads / clock domain | 03/04 | Fixed from attended verification: short adapter frames, commands, and acks publish without EOF; watchdog supervision uses the worker's awake clock. |
| Noro hit target | 05 | PASS attended Mac and Windows: transparent 12 px layer receives hardware input; Windows A/B is pixel-identical. |
| stale result narrative | 05 | Fixed: attended and CI evidence are reported separately, with only the 2x attended gap left open. |

| Final targeted item | Owning layer | Accepted state |
|---|---|---|
| acknowledgement backpressure | 03 | Fixed: one nonblocking send attempt on the shared loop; failure stops/shuts down the per-widget channel and uses the existing crash-restart path. The unrelated-widget latency test passes on both macOS architectures. |
| PR #36 review gate | 04 | PASS: exact head `ddcbc9e` is fully green and Greptile re-scored it 5/5 with zero P1s. |

## Next executable task

None. The five-layer draft stack is ready for human review. The only remaining
attended product gap is the explicitly recorded real 2x playback-rate session;
the implementation path remains unit-covered.
