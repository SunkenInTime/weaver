# macOS unattended run status

Live handoff for an unattended Lane D implementation run. The agent updates
this document after every coherent stacked-PR layer and before ending the run.
Do not leave a question for a human; record the chosen assumption or exact
blocker and the next executable command.

## Run identity

- State: `IN PROGRESS — PR 04 Native SDK pushed; Weaver layer validated for publication`
- Started: 2026-07-15T01:20:00-07:00
- Last updated: 2026-07-15T03:19:29-07:00
- Mac hardware: MacBook Air (Apple M2, 8 cores, 8 GB)
- macOS build: 26.5.1 (25F80)
- Architecture: arm64
- Zig / Node versions: Zig 0.16.0 / Node 23.11.0 locally; Node 22 in CI

## Stack heads

| Stack | Top branch | Commit | Draft PR | Parent/base |
|---|---|---|---|---|
| Native SDK fork | `macos/03-display-contract` | `f214d4d1` | [#3](https://github.com/SunkenInTime/native/pull/3) | [#2](https://github.com/SunkenInTime/native/pull/2) |
| Weaver | `macos/04-display-anchoring` | pending | pending | [#5](https://github.com/SunkenInTime/weaver/pull/5) |

## Last reproducible capability

- Capability: exact primary-display visible-frame anchors for the direct software Clock on AppKit
- Checkout/pointer: `macos/04-display-anchoring`; Native SDK `f214d4d1` (`macos/03-display-contract`)
- Commands: see `docs/macos-m3-results.md`
- Visible result: the 240 x 110 Clock lands at all four 24-point-offset corners on the attached 2x Retina display
- Machine-readable evidence: `NSScreen` full/visible frames, host anchor traces, exact `CGWindow` frames/layer, activation policy/frontmost-app checks, pure signed-origin tests, native/macOS/Windows-cross regression gates

## Gates

| Gate | State | Evidence or exact blocker |
|---|---|---|
| Build/toolchain | PASS | Zig 0.16.0 installed; M0 commands and exact runtime blockers recorded in `docs/macos-m0-results.md` |
| Direct software Clock | PASS | Direct production launch plus correlated CG-window/log/automation evidence in `docs/macos-m2-results.md` |
| AppKit window contract | UNVERIFIED | PR 02 implementation and automated/CG/focus gates pass; required OS recording blocked by ScreenCaptureKit TCC `-3801` (`The user declined TCCs for application, window, display capture`) |
| Display/Spaces behavior | UNVERIFIED | All four anchors physically pass at Retina 2x and Mission Control/focus policy pass; only one display is attached, Stage Manager is disabled, Show Desktop automation is permission-blocked, sleep cannot be safely completed unattended, and OS capture fails with `could not create image from display` |
| Network parity | pending | — |
| Renderer bakeoff | pending | — |
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

## Exact blockers

- `weaverd` and `weaver-renderer` remain Windows-only build graphs until PRs 09-10 and the PR 06 renderer decision.
- macOS HTTPS requests fail explicitly until PR 05 provides the transport. URL/origin policy itself is portable and tested.
- Computer-use recording is unavailable: Chronicle is not running and ScreenCaptureKit returned TCC error `-3801`. Independent layers continue; a permissioned rerun must attach PR 02's recording.
- PR 04 physical topology coverage is hardware-limited to the integrated display. Scaled modes, secondaries on every side, and disconnect/reconnect require external display hardware; Stage Manager, Show Desktop, Space switching, and sleep/wake require a permissioned supervised run that may safely alter desktop state.
- The optional Native SDK Chromium host cannot be linked locally because the CEF SDK layout is absent (`missing CEF dependency for -Dweb-engine=chromium`; install hint: `native cef install --dir ../../third_party/cef/macos`). The system-engine host and its ABI link pass.

## Cleanup state

- Test processes: macOS policy harness, stock GPU example, Clock, and StorageProbe terminated; no Accessibility warning helper remains
- Ephemeral sockets/endpoints: none created
- Temporary registrations/data: PR 03's synthetic storage value, probe log, and oversized Clock backup removed after recording evidence
- Reversible System Settings restored: unchanged
- Working trees/submodule clean: Native SDK clean at `f214d4d1`; Weaver PR 04 files are the current coherent publication set
- Latest stack branches pushed: Weaver PRs 01-03 and Native SDK fork PRs 01-03 pushed

## Next executable task

1. Commit/push the Weaver PR 04 pointer, manifest mapping, results, and live handoff; open its draft PR on PR 03.
2. Inspect PR 04 CI and correct actionable failures without weakening coverage.
3. Start PR 05 deterministic macOS HTTPS transport behind the existing request/result contract.
