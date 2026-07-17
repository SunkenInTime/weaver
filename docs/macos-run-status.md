# macOS unattended run status

Live handoff for an unattended Lane D implementation run. The agent updates
this document after every coherent stacked-PR layer and before ending the run.
Do not leave a question for a human; record the chosen assumption or exact
blocker and the next executable command.

## Run identity

- State: `IN PROGRESS — PR 06 pushed; CI pending`
- Started: 2026-07-15T01:20:00-07:00
- Last updated: 2026-07-15T04:19:28-07:00
- Mac hardware: MacBook Air (Apple M2, 8 cores, 8 GB)
- macOS build: 26.5.1 (25F80)
- Architecture: arm64
- Zig / Node versions: Zig 0.16.0 / Node 23.11.0 locally; Node 22 in CI

## Stack heads

| Stack | Top branch | Commit | Draft PR | Parent/base |
|---|---|---|---|---|
| Native SDK fork | `macos/04-renderer-bakeoff` | `18e9498c` | [#4](https://github.com/SunkenInTime/native/pull/4) | [#3](https://github.com/SunkenInTime/native/pull/3) |
| Weaver | `macos/06-renderer-bakeoff` | `8b220fc` | [#8](https://github.com/SunkenInTime/weaver/pull/8) | [#7](https://github.com/SunkenInTime/weaver/pull/7) |

## Last reproducible capability

- Capability: measured whole-process macOS renderer decision with production packet/frame attribution and pixel/API/input parity
- Checkout/pointer: `macos/06-renderer-bakeoff`; Native SDK `18e9498c` (`macos/04-renderer-bakeoff`)
- Commands: see `docs/macos-m5-results.md` and `scripts/macos-renderer-bakeoff.py`
- Visible result: real Clock, Pomodoro/parity, and 60 Hz synthetic Widgets ran through software, retained Metal-hybrid, and retained Metal-composite candidates and terminated cleanly
- Machine-readable evidence: 1/3/10 whole-process CPU, footprint, VM-region, wakeup/energy, thread/descriptor, frame-stage, precompiled-metallib, resource-lifetime, pixel-delta, API/input, and teardown results in `docs/macos-m5-data.json`

## Gates

| Gate | State | Evidence or exact blocker |
|---|---|---|
| Build/toolchain | PASS | Zig 0.16.0 installed; M0 commands and exact runtime blockers recorded in `docs/macos-m0-results.md` |
| Direct software Clock | PASS | Direct production launch plus correlated CG-window/log/automation evidence in `docs/macos-m2-results.md` |
| AppKit window contract | UNVERIFIED | PR 02 implementation and automated/CG/focus gates pass; required OS recording blocked by ScreenCaptureKit TCC `-3801` (`The user declined TCCs for application, window, display capture`) |
| Display/Spaces behavior | UNVERIFIED | All four anchors physically pass at Retina 2x and Mission Control/focus policy pass; only one display is attached, Stage Manager is disabled, Show Desktop automation is permission-blocked, sleep cannot be safely completed unattended, and OS capture fails with `could not create image from display` |
| Network parity | PASS | Ephemeral NSURLSession transport plus 12/12 runtime suite; deterministic loopback TLS covers success, timeout, caps, redirect denial, malformed URL, certificate failure, and active-request cancellation; production probe returned 200 |
| Renderer bakeoff | PASS | Native #4 + Weaver #8; ADR 0012 selects in-process retained Metal composite, software reference/live fallback, non-adaptive policy, and no shared service from captured 1/3/10-Widget totals |
| Production renderer | pending | — |
| CLI/artifact lifecycle | pending | — |
| macOS daemon / `weaver dev` | pending | — |
| CPU/memory providers | pending | — |
| Audio decision/implementation | pending | — |
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

## Assumptions made autonomously

- The provisional developer-build floor is macOS 13.0 from Zig 0.16.0's host support. PR 12 owns the final floor.
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
- Every healthy macOS Widget will use the in-process Metal-composite architecture selected by ADR 0012. Software remains the bounded pixel reference and live fallback, backend choice is not workload-adaptive, and no renderer/window service is added. PR 07 owns the production switch and recovery policy.
- PR 06's real-Widget mixed workload uses Clock, idle Pomodoro, and the retained/canvas parity Widget. System and Visualizer are not replaced with synthetic provider data before their honest endpoints arrive in PRs 10-13.

## Exact blockers

- `weaverd` and `weaver-renderer` remain Windows-only build graphs until PRs 09-10. ADR 0012 rejects a macOS shared renderer service, so the daemon port no longer waits on a renderer-architecture decision.
- Computer-use recording is unavailable: Chronicle is not running and ScreenCaptureKit returned TCC error `-3801`. Independent layers continue; a permissioned rerun must attach PR 02's recording.
- PR 04 physical topology coverage is hardware-limited to the integrated display. Scaled modes, secondaries on every side, and disconnect/reconnect require external display hardware; Stage Manager, Show Desktop, Space switching, and sleep/wake require a permissioned supervised run that may safely alter desktop state.
- The optional Native SDK Chromium host cannot be linked locally because the CEF SDK layout is absent (`missing CEF dependency for -Dweb-engine=chromium`; install hint: `native cef install --dir ../../third_party/cef/macos`). The system-engine host and its ABI link pass.
- Whole-SoC process/GPU power attribution is unavailable unattended: `powermetrics --show-process-energy` exits `powermetrics must be invoked as the superuser`. PR 06 records the narrower public `proc_pid_rusage(RUSAGE_INFO_V6)` process counters; PR 07 still requires permissioned Instruments Energy and Metal System Trace captures.

## Cleanup state

- Test processes: macOS policy harness, stock GPU example, all renderer-bakeoff Widgets, Clock, StorageProbe, NetworkProbe, and loopback HTTPS server terminated; no Accessibility warning helper remains
- Ephemeral sockets/endpoints: none created
- Temporary registrations/data: PR 03's synthetic storage value, oversized Clock backup, generated TLS key/certificate, and temporary NetworkProbe bundle removed after recording evidence; raw renderer run reports remain only under ignored root `.zig-cache`
- Reversible System Settings restored: unchanged
- Working trees/submodule clean: clean after Weaver PR 06 implementation commit; Native SDK clean at `18e9498c`
- Latest stack branches pushed: Weaver PRs 01-06 and Native SDK fork PRs 01-04 pushed

## Next executable task

1. Inspect Weaver PR 06 and Native SDK PR 04 CI and correct actionable failures without weakening coverage.
2. Create Native `macos/05-production-renderer` from `macos/04-renderer-bakeoff` and Weaver `macos/07-production-renderer` from `macos/06-renderer-bakeoff`.
3. Implement ADR 0012 completely: precompiled metallib, process-lifetime immutable cache, bounded upload/scratch reuse, static/occlusion parking, software demotion/recovery, and status/cost attribution; then execute PR 07's long-duration and physical gates.
