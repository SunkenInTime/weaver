# macOS unattended run status

Live handoff for an unattended Lane D implementation run. The agent updates
this document after every coherent stacked-PR layer and before ending the run.
Do not leave a question for a human; record the chosen assumption or exact
blocker and the next executable command.

## Run identity

- State: `IN PROGRESS — PR 02 pushed; CI pending`
- Started: 2026-07-15T01:20:00-07:00
- Last updated: 2026-07-15T02:13:40-07:00
- Mac hardware: MacBook Air (Apple M2, 8 cores, 8 GB)
- macOS build: 26.5.1 (25F80)
- Architecture: arm64
- Zig / Node versions: Zig 0.16.0 / Node 23.11.0 locally; Node 22 in CI

## Stack heads

| Stack | Top branch | Commit | Draft PR | Parent/base |
|---|---|---|---|---|
| Native SDK fork | `macos/01-appkit-windowing` | `819e878a` | [#1](https://github.com/SunkenInTime/native/pull/1) | `weaver-main` |
| Weaver | `macos/02-appkit-windowing` | `9e74535` | [#4](https://github.com/SunkenInTime/weaver/pull/4) | [#3](https://github.com/SunkenInTime/weaver/pull/3) |

## Last reproducible capability

- Capability: AppKit projection of transparent/chromeless, layer, pass-through, and nonactivating widget windows
- Checkout/pointer: `macos/02-appkit-windowing`; Native SDK `819e878a` (`macos/01-appkit-windowing`)
- Commands: see `docs/macos-m1-results.md`
- Visible result: six-window layer/input harness launched; recording `UNVERIFIED` because the unattended process lacks Screen Recording permission
- Machine-readable evidence: six on-screen CG windows at the intended levels/bounds; focus hand-back; stock/default policy comparison; Native SDK suites

## Gates

| Gate | State | Evidence or exact blocker |
|---|---|---|
| Build/toolchain | PASS | Zig 0.16.0 installed; M0 commands and exact runtime blockers recorded in `docs/macos-m0-results.md` |
| Direct software Clock | pending | — |
| AppKit window contract | UNVERIFIED | Implementation, automated gates, CG inventory, and focus query pass; required recording blocked by ScreenCaptureKit TCC `-3801` (`The user declined TCCs for application, window, display capture`) |
| Display/Spaces behavior | pending | — |
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

## Assumptions made autonomously

- The provisional developer-build floor is macOS 13.0 from Zig 0.16.0's host support. PR 12 owns the final floor.
- `macos-15` (Apple silicon) and `macos-15-intel` are the initial CI runners; physical Intel behavior/performance remains unverified.
- PR 01 carries no visible/runtime performance claim and therefore requires no computer-use capture.
- PR 02 uses desktop-icon-minus-one as the provisional bottom level after measuring desktop/icon/normal/floating levels on the physical M2. PR 04 revalidates it under macOS desktop-management modes.
- An unbundled widget process returns transient AppKit startup activation to the first visible regular application in the public front-to-back CG window list. Bundled packaging still needs the matching agent-app metadata in PR 14.

## Exact blockers

- Full `weaver-widget` build is intentionally blocked at the enumerated Win32 source modules in `manifest.zig`, `provider.zig`, and `widget_log.zig`; PRs 03-05 own those implementations.
- `weaverd` and `weaver-renderer` remain Windows-only build graphs until PRs 09-10 and the PR 06 renderer decision.
- Computer-use recording is unavailable: Chronicle is not running and ScreenCaptureKit returned TCC error `-3801`. Independent layers continue; a permissioned rerun must attach PR 02's recording.

## Cleanup state

- Test processes: macOS policy harness and stock GPU example terminated
- Ephemeral sockets/endpoints: none created
- Temporary registrations/data: none created
- Reversible System Settings restored: unchanged
- Working trees/submodule clean: clean after the PR 02 status update; submodule clean
- Latest stack branches pushed: Weaver PRs 01-02 and Native SDK fork PR 01 pushed

## Next executable task

1. Inspect PR 02 CI and correct actionable failures without weakening coverage.
2. Create `macos/03-runtime-clock` from PR 02 for portable runtime services and the direct software Clock.
