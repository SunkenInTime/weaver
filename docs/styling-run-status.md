# Styling breadth run status

Updated: 2026-07-21 (Windows 11, unattended run)

## Stack map

| Layer | Weaver | Native SDK fork | State |
|---|---|---|---|
| 01 / N1 | [`styling/01-spacing-sizing`](https://github.com/SunkenInTime/weaver/pull/19), implementation through `279a877516c683cae82ae5b4edf35af0d7ab624c` | [`styling/N1-layout-spacing`](https://github.com/SunkenInTime/native/pull/7) at `1a02e1599749f5dab7f366b6af6e0a80dd86e8b1` | complete, pushed, draft PRs open |
| 02 / N2 | [`styling/02-flex-completeness`](https://github.com/SunkenInTime/weaver/pull/20), implementation `f646b7ecb3b979cb01ec04551dc9ee54fbc4e8f5` | [`styling/N2-flex`](https://github.com/SunkenInTime/native/pull/8) at `83a92a0dae98d2bb66e6c94b7315a9cf29df20cf` | complete, pushed, draft PRs open |
| 03 / N3 | [`styling/03-radii-borders`](https://github.com/SunkenInTime/weaver/pull/21), implementation `01c49e0` | [`styling/N3-radii-borders`](https://github.com/SunkenInTime/native/pull/9) at `e26de471a25b0293d270cf31517eb6e5c6936b31` | complete, pushed, draft PRs open |
| 04 | [`styling/04-palette`](https://github.com/SunkenInTime/weaver/pull/22), implementation `4d0c4a8` | none | complete, pushed, draft PR open |
| 05 / N4 | [`styling/05-text-pack`](https://github.com/SunkenInTime/weaver/pull/23), implementation `f9693ae` | [`styling/N4-text`](https://github.com/SunkenInTime/native/pull/10) at `32735626d8ba369e53bedd22a1e3dab46b2c08aa` | complete, pushed, draft PRs open |
| 06 / N5 | [`styling/06-shadows`](https://github.com/SunkenInTime/weaver/pull/24), implementation `5fff1ee` plus final test follow-up `9237c18` | [`styling/N5-shadows`](https://github.com/SunkenInTime/native/pull/11) at `f84552629aa076b134e5a6c21465248be47daf15` | complete, pushed, draft PRs open |
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
- Native N3 focused canvas suite PASS in 35.6s; stock suite PASS in 82.03s; widget-profile suite PASS in 51.61s. Exact commands assert independent corner radii and explicit stroke width/color.
- Weaver 03: `npm test` PASS 28/28; `npm run typecheck` PASS; runtime Zig tests PASS in 7.3s; updated example check and explicit ReleaseFast runtime build PASS. Final dev smoke stayed alive 15s with one startup/no restart and software/pixels presentation.
- Weaver 04: `npm test` PASS 30/30; `npm run typecheck` PASS; runtime Zig tests PASS; CLI build and example check PASS. Dev stayed alive 15s with status `running`, 12s uptime, one startup/no restart, and cleanup left no run-owned process.
- Native N4 focused canvas suite PASS in 41.1s after the final plain-text scale/weight follow-up; stock suite PASS in 76.2s; widget-profile suite PASS in 62.3s. Exact tests cover tracking, tabular digits, two-line clamp/ellipsis, span-path measurement, and retained projection. `zig build validate` PASS. Draft PR: https://github.com/SunkenInTime/native/pull/10.
- Weaver 05: `npm test` PASS 32/32; `npm run typecheck` PASS; runtime `zig build test -Dweb-layer=exclude -Dtrace=off` PASS; CLI build and `weaver check examples/styling-spacing` PASS; explicit ReleaseFast runtime build PASS. Dev smoke produced one startup, software/pixels presentation, status `running` at 35s uptime, and no crash/restart line; the temporary registration and run-owned host were removed.
- Native N5 focused canvas suite PASS in 43.9s; `zig build validate` PASS in 13.1s; final stock suite PASS in 25.2s; widget-profile suite PASS in 69.8s. Exact tests cover reference inset pixels, reference text-shadow pixels, widget panel ordering, and widget text-shadow projection. Draft PR: https://github.com/SunkenInTime/native/pull/11.
- Weaver 06: `npm test` PASS 34/34; `npm run typecheck` PASS; final runtime `zig build test -Dweb-layer=exclude -Dtrace=off` PASS in 7.8s; CLI build and `weaver check examples/styling-shadows` PASS; ReleaseFast runtime build PASS in 117.9s. Isolated dev smoke reached status `running` at 27s uptime with one startup, software/pixels presentation, and no exception/crash/restart line; isolated host/watchers and the temporary registry were removed.

## Assumptions

1. `zig` was absent from `PATH`; use the repository-documented Zig 0.16.0 binary at `E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0\zig.exe`, adding Git's `usr\bin` only for Native validation scripts.
2. The current `SunkenInTime/native:weaver-main` commit `78137351f9463187d95d73092068f02bb3c23d1d` is the binding Native stack base because it is the submodule pin on virgin Weaver `master` and the remote branch head.
3. Tailwind-compatible fraction utilities accept positive `A/B` with `A <= B` and `B > 0`; values outside that range remain unknown utilities with fix-its (`w-0` remains the zero-size form).
4. The API breadth order explicitly includes `w-auto`; it is implemented as a left-to-right reset of fixed and percentage size on that axis even though the wire table represents auto by absence.
5. Negative Tailwind margins are part of exact Tailwind semantics and are implemented although the brief's examples only show positive margins.
6. macOS-specific visual behavior cannot be exercised on this Windows machine; CI compile gates are evidence only, and physical behavior stays `UNVERIFIED (needs Mac)`.
7. Tailwind's default `flex-shrink: 1` is Weaver-specific projection; Native SDK's public default remains zero to preserve existing Native applications, while every Weaver retained node defaults to one.
8. Tailwind border numeric suffixes are literal pixel widths (`border-2` = 2px), not spacing-scale units; arbitrary `[Npx]` is also accepted and per-side borders remain deferred by the brief.
9. Radius classes resolve left-to-right per affected corner: a later uniform radius clears earlier corner overrides, while a later side/corner utility overrides only its selected corners.
10. "Tailwind v4" is pinned to the current published `tailwindcss@4.3.3` palette (286 shade names, including mauve/olive/mist/taupe) at tarball shasum `c006861611c213c1877893ab5b23daa16be2bb55`. Because the frozen Weaver wire accepts only RGBA8, official OKLCH values are converted through the CSS Color 4 OKLab-to-sRGB matrix with channel clipping and byte rounding; named `/NN` multiplies existing alpha so `transparent/NN` stays transparent.
11. Tailwind text alignment maps physical `text-left/right` to the contract's available logical `start/end`; Weaver has no bidi direction property yet.
12. Tailwind line-height semantics are frozen as named multipliers (`none` 1, `tight` 1.25, `snug` 1.375, `normal` 1.5, `relaxed` 1.625, `loose` 2); numeric `leading-N` uses the 4px spacing scale, bracketed unitless values are multipliers, and pixel forms resolve against the final font size regardless of class order.
13. Named and arbitrary-em tracking resolve to logical pixels against the final font size regardless of class order; arbitrary pixel tracking is stored verbatim and may be negative.
14. Weaver clamps `lineClamp` to Native SDK's existing 64-line paragraph capacity at projection time. Compiler utilities still preserve the requested positive integer on the wire; values above 64 render as 64 lines rather than exceeding bounded Native storage.
15. Clamped and truncated Weaver text uses Native's plain text path so `text_layout.zig` owns wrap/ellipsis; Native N4 adds plain-leaf scale/weight fields to preserve arbitrary font size and weight. Unclamped text keeps the existing inline-span path.
16. Weaver's frozen shadow wire carries one shadow, so Tailwind's multi-layer preset shapes are represented by one primary layer: `sm=0 1 2 0`, default=`0 1 3 0`, `md=0 4 6 -1`, `lg=0 10 15 -3`, and `xl=0 20 25 -5`, with the documented preset alpha. Multiple comma-separated CSS shadows remain out of scope.
17. Arbitrary box shadows use underscore-separated class syntax `shadow-[x_y_blur_spread_#hex]`, accept optional `px` suffixes, require a non-negative blur, and allow negative offsets/spread. This is the narrowest class-safe encoding of the brief's packed wire tuple.
18. Shadow geometry and `shadow-<palette>` color resolve independently after the complete class string, making their result order-independent. A color utility without shadow geometry is accepted but emits no visible shadow until a geometry utility is also present.

## UNVERIFIED / BLOCKED

- `UNVERIFIED (needs Mac)`: N1 shared-layout behavior on the macOS reference and Metal presentation paths. Evidence available now: platform-neutral Native Zig suites pass on Windows; await PR CI for compile gates and Mac hardware for physical pixels.
- `BLOCKED (unrelated Native fast gate)`: `scripts/gate.sh fast origin/weaver-main` fails `examples-native` because five existing example switches omit the already-present `runtime.api.Event.window_frame` member. Evidence: `capabilities`, `native-panels`, `command-app`, `native-shell`, and `gpu-components` compile errors; changed canvas suite and the required stock/profile suites pass.
- The same unrelated `examples-native` failure reproduced for N2 against N1; all other affected fast-gate groups passed.
- The same unrelated `examples-native` failure reproduced for N3 against N2; zig-test, validate, frontend examples, and mobile examples passed.
- `UNVERIFIED (needs Mac)`: N3 asymmetric surface pixels. Evidence available now: Native exact display-list radius/stroke assertions and all Windows stock/profile suites pass; physical macOS output remains unobserved.
- `UNVERIFIED (needs Mac)`: N4 CoreText kern and monospaced-number feature application, plus physical clamp/alignment pixels. Evidence available now: Objective-C packet wiring, platform-neutral exact tests, static validation, and both full Windows suites pass; macOS compilation/physical output awaits CI/hardware.
- `BLOCKED (unrelated Native fast gate)`: N4 fast gate reproduces the same five `examples-native` exhaustive-switch failures for the pre-existing `window_frame` event. The N4 changed canvas tests, validate, frontend, and mobile groups pass; macOS-only CEF link validation is skipped on Windows.
- `UNVERIFIED (needs Mac)`: N5 AppKit v5 packet decoding, inverse-path inset clipping, and `NSShadow` text pixels. Evidence available now: packet/prose ratchets, exact platform-neutral tests, static validation, and both Windows full suites pass; Objective-C compilation and physical pixels await macOS CI/hardware.
- `BLOCKED (unrelated Native fast gate)`: N5 fast gate against N4 passes zig-test (34s), validate, frontend examples, and mobile examples (44s), but the same five `examples-native` switches omit pre-existing `window_frame`. Apple-Silicon benchmarks and macOS CEF link are skipped on Windows.
- `RESOLVED during N5`: the first final full-suite pass found the schema ratchet and macOS decoder prose still naming v4 after the v5 packet change; both were updated and pushed. One intervening Windows run also hit transient `error.Unexpected` while creating an iOS test asset directory; an immediate clean rerun passed in 25.2s.
- `RESOLVED during PR03`: the first `weaver dev` attempt used a stale runtime after a parallel ReleaseFast build was canceled by the stale-CLI check failure, causing three `unsupported property` crash restarts. An explicit runtime rebuild followed by a fresh 15s smoke produced one startup and no exception/restart. Both outcomes are in PR21 evidence.

## Cleanup state

- Work is confined to `E:\Projects\weaver-styling-run` and its submodule.
- No default branch was changed or merged; no frozen `weaver-fork*` branch was extended.
- No Weaver dev process is currently running.
- Isolated PR 01 dev data under `%TEMP%\weaver-styling-run-pr01` was removed after shutdown.
- PR06 isolated data under `.dev-smoke-pr06` was removed after `weaver down`; all clone-owned dev watchers and their esbuild helpers were stopped. The cleanup also removed one stale PR05 spacing watcher discovered during the audit.

## Next executable task

Branch `styling/07-fonts` from PR06 and audit the existing bundle/font registry seams before implementing discovery, validation, pack transport, registration, family selection, and weight degradation.
