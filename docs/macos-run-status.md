# macOS unattended run status

Live handoff for an unattended Lane D implementation run. The agent updates
this document after every coherent stacked-PR layer and before ending the run.
Do not leave a question for a human; record the chosen assumption or exact
blocker and the next executable command.

## Run identity

- State: `IN PROGRESS — PR 01 pushed; CI pending`
- Started: 2026-07-15T01:20:00-07:00
- Last updated: 2026-07-15T01:42:05-07:00
- Mac hardware: MacBook Air (Apple M2, 8 cores, 8 GB)
- macOS build: 26.5.1 (25F80)
- Architecture: arm64
- Zig / Node versions: Zig 0.16.0 / Node 23.11.0 locally; Node 22 in CI

## Stack heads

| Stack | Top branch | Commit | Draft PR | Parent/base |
|---|---|---|---|---|
| Native SDK fork | — | — | — | `weaver-main` |
| Weaver | `macos/01-build-seams` | `9ba2024` | [#3](https://github.com/SunkenInTime/weaver/pull/3) | `master` |

## Last reproducible capability

- Capability: macOS/Windows compile-time runtime platform seam and macOS Node/Native SDK baseline
- Checkout/pointer: `macos/01-build-seams`; Native SDK `1a2b3368` (`origin/weaver-main`)
- Commands: see `docs/macos-m0-results.md`
- Visible result: none claimed at M0
- Machine-readable evidence: 20/20 Node tests; runtime platform-service test; Native SDK stock and widget-profile suites

## Gates

| Gate | State | Evidence or exact blocker |
|---|---|---|
| Build/toolchain | PASS | Zig 0.16.0 installed; M0 commands and exact runtime blockers recorded in `docs/macos-m0-results.md` |
| Direct software Clock | pending | — |
| AppKit window contract | pending | — |
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

## Exact blockers

- Full `weaver-widget` build is intentionally blocked at the enumerated Win32 source modules in `manifest.zig`, `provider.zig`, and `widget_log.zig`; PRs 03-05 own those implementations.
- `weaverd` and `weaver-renderer` remain Windows-only build graphs until PRs 09-10 and the PR 06 renderer decision.

## Cleanup state

- Test processes: no Weaver process launched at M0
- Ephemeral sockets/endpoints: none created
- Temporary registrations/data: none created
- Reversible System Settings restored: unchanged
- Working trees/submodule clean: clean after the PR 01 status update; submodule clean
- Latest stack branches pushed: PR 01 pushed

## Next executable task

1. Inspect PR 01 CI and correct actionable failures without weakening coverage.
2. Create Native SDK `macos/01-appkit-windowing` from `weaver-main` for PR 02.
