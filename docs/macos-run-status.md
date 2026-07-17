# macOS unattended run status

Live handoff for an unattended Lane D implementation run. The agent updates
this document after every coherent stacked-PR layer and before ending the run.
Do not leave a question for a human; record the chosen assumption or exact
blocker and the next executable command.

## Run identity

- State: `IN PROGRESS — PR 13 pushed; CI pending`
- Started: 2026-07-15T01:20:00-07:00
- Last updated: 2026-07-15T07:46:00-07:00
- Mac hardware: MacBook Air (Apple M2, 8 cores, 8 GB)
- macOS build: 26.5.1 (25F80)
- Architecture: arm64
- Zig / Node versions: Zig 0.16.0 / Node 23.11.0 locally; Node 22 in CI

## Stack heads

| Stack | Top branch | Commit | Draft PR | Parent/base |
|---|---|---|---|---|
| Native SDK fork | `macos/05-production-renderer` | `359f5c9c` | [#5](https://github.com/SunkenInTime/native/pull/5) | [#4](https://github.com/SunkenInTime/native/pull/4) |
| Weaver | `macos/13-production-audio` | `8b7f211` | [#15](https://github.com/SunkenInTime/weaver/pull/15) | [#14](https://github.com/SunkenInTime/weaver/pull/14) |

## Last reproducible capability

- Capability: one signed host-owned macOS audio capture feeds the unchanged shared FFT/AGC/final-zero pipeline and two real Visualizer processes; authorization, revocation, device loss, recovery, fan-out, parking, and teardown are explicit and deterministic
- Checkout/pointer: `macos/13-production-audio` result head `4ed9195`, implementation and measured workload `ba1336b`; Native SDK remains `359f5c9c` (`macos/05-production-renderer`)
- Commands: `cd host && zig build test && zig build`; `npm run build`; `npm run typecheck`; `npm test`; `node cli/test/macos-host-smoke.mjs`; `python3 scripts/macos-audio-cost.py --sample-seconds 10 --output docs/macos-m10-data.json`; `codesign --verify --deep --strict host/zig-out/Weaverd.app`
- Visible result: deterministic 440 Hz injection drives two real Metal Visualizer Widgets through the production C/Zig/UDS/runtime seam; silence parks both after one final zero, while fresh real System Audio Recording consent remains unapprovable because Chronicle and System Events control are unavailable
- Machine-readable evidence: `docs/macos-m10-results.md`, `docs/macos-m10-data.json`, exact availability/capture/frame/error counters, both Widget logs, signed bundle verification, 22/22 root tests, host tests, full daemon smoke, and zero process/socket/registration remnants

## Gates

| Gate | State | Evidence or exact blocker |
|---|---|---|
| Build/toolchain | PASS | Zig 0.16.0 installed; M0 commands and exact runtime blockers recorded in `docs/macos-m0-results.md` |
| Direct software Clock | PASS | Direct production launch plus correlated CG-window/log/automation evidence in `docs/macos-m2-results.md` |
| AppKit window contract | UNVERIFIED | PR 02 implementation and automated/CG/focus gates pass; required OS recording blocked by ScreenCaptureKit TCC `-3801` (`The user declined TCCs for application, window, display capture`) |
| Display/Spaces behavior | UNVERIFIED | All four anchors physically pass at Retina 2x and Mission Control/focus policy pass; only one display is attached, Stage Manager is disabled, Show Desktop automation is permission-blocked, sleep cannot be safely completed unattended, and OS capture fails with `could not create image from display` |
| Network parity | PASS | Ephemeral NSURLSession transport plus 12/12 runtime suite; deterministic loopback TLS covers success, timeout, caps, redirect denial, malformed URL, certificate failure, and active-request cancellation; production probe returned 200 |
| Renderer bakeoff | PASS | Native #4 + Weaver #8; ADR 0012 selects in-process retained Metal composite, software reference/live fallback, non-adaptive policy, and no shared service from captured 1/3/10-Widget totals |
| Production renderer | PASS | Native #5 + Weaver #9; embedded metallib, process-lifetime resources, bounded scratch reuse, static/occlusion parking, same-frame software demotion, automatic recovery, pixel parity, 10-minute active/static runs, cover/reveal, and 20-cycle lifecycle all pass; Instruments is AMFI-blocked and sleep/external-display remain explicitly UNVERIFIED |
| CLI/artifact lifecycle | PASS | Weaver #10 passes the same fixed-byte pack/open/inspect/install, containment, rollback, replacement, abandoned lock/stage, cleanup, uninstall, directory ownership, and logs driver on Windows, Apple silicon, and Intel; the original PowerShell Windows smoke also remains green |
| macOS daemon / `weaver dev` | PASS | Weaver #12; `macos-host-smoke.mjs` proves init/dev/edit preserved-state hot swap/config restart/stop, concurrent mutations, provider UDS, host + Widget adverse kills, backoff/recovery/status, and zero process/socket/lock remnants |
| CPU/memory providers | UNVERIFIED | Weaver #13 functional/fan-out/cost/zero-collection gates pass; required sleep/wake remains unsafe on the only unattended machine and is not inferred |
| Audio decision/implementation | UNVERIFIED | ADR 0014 decision PASS; PR 13 production code, deterministic end-to-end Visualizers, denial/allow/revoke/device-loss state machine, one-capture fan-out, final-zero parking, injected cost, and teardown PASS. Real TCC grant, callback/mix/cost, physical routes, Bluetooth, and AirPlay remain unverified |
| Media decision/implementation | pending | — |
| Full CI/regression closure | pending | — |

Use `PASS`, `FAIL`, `BLOCKED`, `UNVERIFIED`, or `pending`. A blocked gate does
not stop independent work.

## Measurements

Record links to raw results and Instruments captures. Include total cost across
host, Widgets, providers, and any renderer—not only the process that improved.

| Workload | Backend/architecture | CPU | Footprint/memory | Wakeups/energy | Frames/latency | Evidence |
|---|---|---:|---:|---:|---:|---|
| Direct Clock, steady-state 1 Hz | CPU reference renderer; AppKit pixel presenter; one process | 0.79% mean of one core (10 x 1 s samples) | 86 MB physical; 90 MB peak; 5–6 threads | not captured | first visible window about 307 ms in verbose launch; full trace deferred | `docs/macos-m2-results.md` |
| Anchored Clock, steady-state 1 Hz | same renderer/presenter; three conditional desktop observers | 0.70% mean of one core (5 x 1 s samples) | 91 MB physical/peak; 6 threads | not captured | exact four-corner placement; no latency claim | `docs/macos-m3-results.md` |
| Clock with idle network capability, steady-state 1 Hz | no session/queue/worker until fetch; one process | 0.92% mean of one core (5 x 1 s samples) | 90 MB physical/peak; 6 threads | not captured | no active request; PR05 binary +23,920 bytes | `docs/macos-m4-results.md` |
| 10 Clocks, steady-state 1 Hz | software / Metal hybrid / Metal composite; ten isolated processes | 6.71% / 2.74% / 2.73% | 930.866 / 944.154 / 989.505 MB physical | 577.14 / 573.56 / 567.73 interrupt wakeups/s; 71.554 / 23.221 / 29.109 process mJ/s on independent runs | 1 Hz updates; no static-zero-update claim | `docs/macos-m5-results.md`, `docs/macos-m5-data.json` |
| Synthetic, sustained 60 Hz | software / Metal hybrid / Metal composite; one process | 98.99% / 34.74% / 23.91% | 108.086 / 120.489 / 123.045 MB physical | 124.78 / 110.58 / 83.28 wakeups/s; 4965.233 / 184.508 / 144.453 process mJ/s | composite frame interval p50 16.660 ms, p90 17.667 ms | `docs/macos-m5-results.md`, `docs/macos-m5-data.json` |
| Synthetic, sustained 60 Hz | software / Metal hybrid / Metal composite; three processes | 302.85% / 73.98% / 61.11% | 324.373 / 361.139 / 378.899 MB physical | 331.47 / 325.95 / 334.08 wakeups/s; 15051.751 / 712.669 / 506.738 process mJ/s | same production workload in every candidate | `docs/macos-m5-results.md`, `docs/macos-m5-data.json` |
| Synthetic, sustained 60 Hz | production Metal composite; one process, 10 minutes | 23.61% mean | 123.782 MB final; 127.567 MB peak; 6–8 threads; 34 FDs | 87.22 wakeups/s; 158.794 process mJ/s | p50/p90/p99 16.666/16.704/18.270 ms; 4 of 36,410 intervals over 25 ms; zero transitions | `docs/macos-m6-results.md`, `docs/macos-m6-data.json` |
| Retained parity, zero updates | production Metal composite; one process, 10 minutes | 0.006% mean | 110.265 MB final; 118.211 MB peak; 5–7 threads; 34 FDs | 1.11 wakeups/s; 0.019 process mJ/s | three startup/reveal frames, then fully parked; zero transitions | `docs/macos-m6-results.md`, `docs/macos-m6-data.json` |
| Host, zero system subscribers | native macOS daemon only; five 1 s samples | 0.14% mean of one core | 1.441 MiB RSS | 2 threads; wakeups not captured | exactly 0 sampler calls / 0 frames | `docs/macos-m8-results.md`, `docs/macos-m8-data.json` |
| Host + one / three System Widgets | one shared Mach sample, UDS fan-out; five 1 s samples | 1.96% / 3.96% whole workload | 156.059 / 428.816 MiB RSS | 9.4 / 24.8 threads; wakeups not captured | 4 sampler calls in both captured boundaries; 8 / 24 frames | `docs/macos-m8-results.md`, `docs/macos-m8-data.json` |
| Core Audio setup-only process | one private global mono tap + aggregate; ten launches, each with intentional 0.5 s sleep | 0.014 s summed CPU / 0.610 s wall mean (2.295% over boundary) | 14,209,843 bytes mean maximum RSS | not captured | no IO proc/callback; no latency claim | `docs/macos-m9-results.md`, `docs/macos-m9-data.json` |
| Host, audio unsubscribed | production signed daemon; ten 1 s samples | 0.17% mean of one core | 2.458 MB aggregate physical footprint; 8.634 MB RSS | not captured | exactly 0 capture starts / provider frames / pipe frames | `docs/macos-m10-results.md`, `docs/macos-m10-data.json` |
| Host + two active Visualizers | one injected production mono source, one FFT, UDS fan-out, two Metal runtime processes; ten 1 s samples | 18.06% whole workload | 100.723 MB aggregate physical footprint; 260.728 MB mean RSS | not captured | 269 provider / 269 pipe frames; exactly one capture start | `docs/macos-m10-results.md`, `docs/macos-m10-data.json` |
| Host + two silent parked Visualizers | capture remains subscribed; FFT output and both Widgets parked after final zero; ten 1 s samples | 0.87% whole workload | 87.549 MB aggregate physical footprint; 194.447 MB mean RSS | not captured | exactly 0 provider / pipe frames during boundary | `docs/macos-m10-results.md`, `docs/macos-m10-data.json` |

## Assumptions made autonomously

- The final macOS floor is 14.2 because the selected public Core Audio process-tap function is available from 14.2. Weaver rejects ScreenCaptureKit and virtual-driver fallbacks rather than retain the provisional 13.0 floor.
- `macos-15` (Apple silicon) and `macos-15-intel` are the initial CI runners; physical Intel behavior/performance remains unverified.
- PR 01 carries no visible/runtime performance claim and therefore requires no computer-use capture.
- PR 02 uses desktop-icon-minus-one as the provisional bottom level after measuring desktop/icon/normal/floating levels on the physical M2. PR 04 revalidates it under macOS desktop-management modes.
- An unbundled widget process returns transient AppKit startup activation to the first visible regular application in the public front-to-back CG window list. Bundled packaging still needs the matching agent-app metadata in PR 14.
- PR 03 discovered that Weaver's software choice could not be reported honestly while the Native SDK hard-coded AppKit frames to Metal. Native SDK PR 02 is an explicit extra stacked dependency; it carries the requested backend/alpha contract and forces CPU pixel presentation for software surfaces.
- Clock's once-per-second update makes its recorded CPU a 1 Hz steady-state baseline, not a static-idle claim. The 86 MB footprint misses the aspirational 15 MiB investigation target and remains an explicit PR 06–07 optimization input.
- The existing manifest's `monitor: primary` remains the complete public selection surface. Native SDK exposes a generic primary-visible-frame corner anchor and enumerates secondary displays only to react to topology changes; no per-monitor selector is added.
- Weaver's macOS Widget path uses the AppKit system engine. The optional Chromium host rejects primary-display anchors explicitly until it implements the same contract; the missing local CEF SDK is recorded rather than bypassed.
- macOS HTTPS uses ephemeral NSURLSession and default system trust. It returns all redirects as their original 3xx (matching WinHTTP's stricter policy), caps total request and response bytes at 5 MiB each, and compiles its generated-certificate trust hook only into tests.
- “Metal composite” means binary retained packets, Core Graphics rasterization for commands that are not native quads, and Metal quad composition/presentation; it is not mislabeled as a fully Metal-native vector renderer.
- Every healthy macOS Widget now uses the in-process Metal-composite architecture selected by ADR 0012. Software remains the bounded pixel reference and live fallback, backend choice is not workload-adaptive, and no renderer/window service is added. Production probes recovery after 1, 5, then 30 seconds.
- PR 06's real-Widget mixed workload uses Clock, idle Pomodoro, and the retained/canvas parity Widget. System and Visualizer are not replaced with synthetic provider data before their honest endpoints arrive in PRs 10-13.
- The first-pixel readback and deterministic Metal fault injector are compiled only into automation builds. Backdrop blur's reused target readback is the sole intentional production GPU readback.
- macOS install/uninstall mutate the same atomic registry and immutable owned-source tree without starting a nonexistent host. Windows keeps its acknowledged host start/reload/rollback behavior; PR 10 connects the macOS host to that already-portable mutation boundary.
- PR 09 keeps platform process state as an opaque generic field owned by the adapter-facing slot type. The supervisor can decide what must happen but cannot create, signal, sample, or terminate a process or IPC endpoint.
- PR 10 uses one acknowledged control UDS and one cryptographically unguessable UDS per provider-subscribed Widget under a mode-0700 per-user root. Long default `TMPDIR` paths fall back to `/tmp` before they can exceed `sun_path`.
- Because macOS has no public kill-on-close Job equivalent, a replacement host kills an orphan only when both its private marker and live `proc_pidpath` match the exact runtime executable. ADR 0013 records the rejected polling/unvalidated-kill alternatives.
- macOS `memory.usedMb` projects the platform-neutral SDK meaning as total physical memory minus free and inactive/reclaimable pages. CPU uses public per-logical-core Mach ticks with wrapping deltas; aggregate percent remains 0–100 rather than summing cores.
- One host-owned private global mono Core Audio tap feeds one shared FFT/AGC/silence pipeline and software fan-out. The host ships as the `com.sunkenintime.weaver.host` signed agent; explicit authorization uses that same identity, while missing permission reports unavailable without fake live-silence frames.
- Deterministic audio injection exists only under `WEAVER_AUTOMATION=1` with an explicit control file and crosses the production capture/analyzer/transport/runtime seam. It proves lifecycle and whole-application injected cost, not a real macOS consent grant or Core Audio callback cost.

## Exact blockers

- Computer-use recording is unavailable: Chronicle is not running and ScreenCaptureKit returned TCC error `-3801`. Independent layers continue; a permissioned rerun must attach PR 02's recording.
- PR 04 physical topology coverage is hardware-limited to the integrated display. Scaled modes, secondaries on every side, and disconnect/reconnect require external display hardware; Stage Manager, Show Desktop, Space switching, and sleep/wake require a permissioned supervised run that may safely alter desktop state.
- The optional Native SDK Chromium host cannot be linked locally because the CEF SDK layout is absent (`missing CEF dependency for -Dweb-engine=chromium`; install hint: `native cef install --dir ../../third_party/cef/macos`). The system-engine host and its ABI link pass.
- Whole-SoC process/GPU power attribution is unavailable unattended: `powermetrics --show-process-energy` exits `powermetrics must be invoked as the superuser`. The run records the narrower public `proc_pid_rusage(RUSAGE_INFO_V6)` process counters.
- Instruments Energy and Metal System Trace are blocked before launch: AMFI kills `xcrun xctrace` with exit 137 and records `dynamic: com.apple.dt.InstrumentsCLI disallowed with com.apple.private.tcc.allow entitlement` followed by `load code signature error 4 for file "xctrace"`. Xcode 16.0's on-disk signature verifies; the exact host failure is retained in `docs/macos-m6-results.md`.
- Fresh System Audio Recording permission is unavailable unattended: the signed, usage-described spike remained blocked in `AudioDeviceCreateIOProcIDWithBlock` after six seconds, Chronicle was not running, and System Events automation also blocked. Real denial/revocation, audible mix, callback latency/cost, and physical route recovery remain `UNVERIFIED`; no Bluetooth or AirPlay route is attached, and no Developer ID identity is installed. Deterministic denial/revoke/device transitions pass but are not substituted for those physical gates.

## Cleanup state

- Test processes: macOS policy harness, stock GPU example, all renderer-bakeoff and production Widgets, opaque cover application, Clock, every single/two/three-Widget System provider fixture, both injected Visualizer fixtures, StorageProbe, NetworkProbe, deliberately crashed/recovered daemon and Widgets, loopback HTTPS server, every audio spike, and blocked System Events helper terminated; no Accessibility warning helper remains
- Ephemeral sockets/endpoints: all PR 10 control/provider sockets, runtime roots, and singleton files removed
- Temporary registrations/data: PR 03's synthetic storage value, oversized Clock backup, generated TLS key/certificate, temporary NetworkProbe bundle, PR 10 Clock/Alpha/Beta/System fixtures, PR 13 Visualizers/control/authorization markers, isolated CLI home/data/log trees, registry locks, install stages, owned versions, scoped audio TCC decision, and temporary audio taps/aggregates removed after recording evidence; ignored spike builds and raw renderer run reports remain only as reproducible local build products
- Reversible System Settings restored: unchanged
- Working trees/submodule clean: clean after this PR 13 ledger commit; Native SDK clean at `359f5c9c`
- Latest stack branches pushed: Weaver PRs 01-13 and Native SDK fork PRs 01-05 pushed; PR 12 is green and PR 13 CI is running

## Next executable task

1. Inspect PR 13 CI and correct actionable failures without weakening coverage.
2. Create `macos/14-media-decision` from PR 13 and complete the public media-provider feasibility/ADR gate.
3. If public system-wide media observation is unavailable, record the honest unavailable decision and omit PR 15 rather than introducing private MediaRemote dependencies.
