# Styling breadth run status

Updated: 2026-07-21 (Windows 11, unattended run)

## Stack map

| Layer | Weaver | Native SDK fork | State |
|---|---|---|---|
| 01 / N1 | [`styling/01-spacing-sizing`](https://github.com/SunkenInTime/weaver/pull/19), implementation through `279a877516c683cae82ae5b4edf35af0d7ab624c` | [`styling/N1-layout-spacing`](https://github.com/SunkenInTime/native/pull/7) at `1a02e1599749f5dab7f366b6af6e0a80dd86e8b1` | complete, pushed, draft PRs open |
| 02 / N2 | [`styling/02-flex-completeness`](https://github.com/SunkenInTime/weaver/pull/20), implementation `f646b7ecb3b979cb01ec04551dc9ee54fbc4e8f5` | [`styling/N2-flex`](https://github.com/SunkenInTime/native/pull/8) at `83a92a0dae98d2bb66e6c94b7315a9cf29df20cf` | complete, pushed, draft PRs open |
| 03 / N3 | `styling/03-radii-borders` | `styling/N3-radii-borders` | pending |
| 04 | `styling/04-palette` | none | pending |
| 05 / N4 | `styling/05-text-pack` | `styling/N4-text` | pending |
| 06 / N5 | `styling/06-shadows` | `styling/N5-shadows` if required | pending |
| 07 | `styling/07-fonts` | registry plumbing in prior fork layer if required | pending |
| 08 | `styling/08-icons` | none expected | pending |
| 09 / N6 | `styling/09-stack-overflow` | `styling/N6-stack-overflow` | pending |
| 10 / N7 | `styling/10-image-v2` | `styling/N7-image-v2` | pending |
| 11 / N8 | `styling/11-interaction` | `styling/N8-interaction` | pending |
| 12 | `styling/12-showcase` | none | pending |

## Completed gates

- Virgin Weaver `master` (`origin/master`): `npm test` PASS 22/22; `npm run typecheck` PASS; `runtime/ zig build test -Dweb-layer=exclude -Dtrace=off` PASS.
- Native N1 focused: `zig build test-canvas -Dwidget-profile=true` PASS.
- Native N1 required full suites: `zig build test` PASS in 79.22s; `zig build test -Dwidget-profile=true` PASS in 57.43s.
- Native N2 focused canvas suite PASS; stock suite PASS in 100.46s; widget-profile suite PASS in 44.63s.
- Weaver 01: `npm test` PASS 25/25; `npm run typecheck` PASS; `runtime/ zig build test -Dweb-layer=exclude -Dtrace=off` PASS.
- Weaver 01 example: `weaver check examples/styling-spacing` PASS; release runtime and host builds PASS; `weaver dev examples/styling-spacing` stayed alive for 15s with status `running`, software backend, 12s runtime uptime, and no crash/restart line. `weaver down` left zero run-owned Weaver processes.
- Weaver 02: `npm test` PASS 26/26; `npm run typecheck` PASS; runtime Zig tests PASS; updated example check and ReleaseFast runtime build PASS. Dev stayed alive 15s, status `running` with 12s uptime, one startup/no restart, and cleanup left zero processes/data.

## Assumptions

1. `zig` was absent from `PATH`; use the repository-documented Zig 0.16.0 binary at `E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0\zig.exe`, adding Git's `usr\bin` only for Native validation scripts.
2. The current `SunkenInTime/native:weaver-main` commit `78137351f9463187d95d73092068f02bb3c23d1d` is the binding Native stack base because it is the submodule pin on virgin Weaver `master` and the remote branch head.
3. Tailwind-compatible fraction utilities accept positive `A/B` with `A <= B` and `B > 0`; values outside that range remain unknown utilities with fix-its (`w-0` remains the zero-size form).
4. The API breadth order explicitly includes `w-auto`; it is implemented as a left-to-right reset of fixed and percentage size on that axis even though the wire table represents auto by absence.
5. Negative Tailwind margins are part of exact Tailwind semantics and are implemented although the brief's examples only show positive margins.
6. macOS-specific visual behavior cannot be exercised on this Windows machine; CI compile gates are evidence only, and physical behavior stays `UNVERIFIED (needs Mac)`.
7. Tailwind's default `flex-shrink: 1` is Weaver-specific projection; Native SDK's public default remains zero to preserve existing Native applications, while every Weaver retained node defaults to one.

## UNVERIFIED / BLOCKED

- `UNVERIFIED (needs Mac)`: N1 shared-layout behavior on the macOS reference and Metal presentation paths. Evidence available now: platform-neutral Native Zig suites pass on Windows; await PR CI for compile gates and Mac hardware for physical pixels.
- `BLOCKED (unrelated Native fast gate)`: `scripts/gate.sh fast origin/weaver-main` fails `examples-native` because five existing example switches omit the already-present `runtime.api.Event.window_frame` member. Evidence: `capabilities`, `native-panels`, `command-app`, `native-shell`, and `gpu-components` compile errors; changed canvas suite and the required stock/profile suites pass.
- The same unrelated `examples-native` failure reproduced for N2 against N1; all other affected fast-gate groups passed.

## Cleanup state

- Work is confined to `E:\Projects\weaver-styling-run` and its submodule.
- No default branch was changed or merged; no frozen `weaver-fork*` branch was extended.
- No Weaver dev process is currently running.
- Isolated PR 01 dev data under `%TEMP%\weaver-styling-run-pr01` was removed after shutdown.

## Next executable task

Branch Native `styling/N3-radii-borders` from N2; add per-corner `WidgetStyle` radii and verify panel stroke projection with renderer tests.
