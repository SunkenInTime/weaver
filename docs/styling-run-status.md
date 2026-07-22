# Styling breadth run status

Updated: 2026-07-23 (Windows 11, unattended path-icon redesign)

## 2026-07-23 path-icon redesign

- PR08 is being rewritten in place: `<icon>` is lowered at bundle time to
  normalized absolute `M`/`L`/`C`/`Z` path data. The font subset, codepoint map,
  reserved face id 64, and icon-font projection are removed.
- Native N5 retains bounded icon-path metadata and projects it through the
  existing display-list path command. D3D keeps its existing per-command CPU
  fallback for paths.
- Assumption: the binding full catalog is `lucide-static@1.26.0` (1,749 names),
  npm tarball SHA-1 `cdaec64ebb9ba10d9ce0fc065184b9dde3eb992d`, integrity
  `sha512-6yCpa2ONICjlE19BuneIi75ASd9cCZhqJlzhAlQBi+99m2aZd2cNzxFVbDgPu7JLBZR2uDYO/EpLYtnhGw5Niw==`.
  Only resolved icon paths are embedded in a widget bundle; the catalog itself
  remains a pinned CLI build dependency.
- Assumption: `svg-pathdata@7.2.0` is the binding bundle-time normalizer. It
  requires Node 20.11.1 or newer, which is compatible with Weaver's existing
  Node 22 development baseline.
- Assumption: the Native widget profile's aggregate path-element allowance is
  raised from 256 to 2,048 so one legal 8 KiB normalized icon path can always
  be retained without growing every `Widget`; per-node normalized data remains
  independently capped at 8 KiB by `weaver check`.
- Assumption: Lucide named icons always use the upstream `0 0 24 24` view box,
  two-unit round stroke, and current text color. Raw `d` icons default to fill;
  a positive `stroke` prop selects round stroked rendering.
- Assumption: Noro's solid controls will use the exact 24-unit Rainmeter paths
  from upstream `NoroPlayer/Player.ini`; this belongs to PR13 and must preserve
  the radii introduced by `4241b12`.

## Stack map

| Layer | Weaver | Native SDK fork | State |
|---|---|---|---|
| 01 / N1 | [`styling/01-spacing-sizing`](https://github.com/SunkenInTime/weaver/pull/19), implementation through `279a877516c683cae82ae5b4edf35af0d7ab624c` | [`styling/N1-layout-spacing`](https://github.com/SunkenInTime/native/pull/7) at `1a02e1599749f5dab7f366b6af6e0a80dd86e8b1` | complete, pushed, draft PRs open |
| 02 / N2 | [`styling/02-flex-completeness`](https://github.com/SunkenInTime/weaver/pull/20), implementation `f646b7ecb3b979cb01ec04551dc9ee54fbc4e8f5` | [`styling/N2-flex`](https://github.com/SunkenInTime/native/pull/8) at `83a92a0dae98d2bb66e6c94b7315a9cf29df20cf` | complete, pushed, draft PRs open |
| 03 / N3 | [`styling/03-radii-borders`](https://github.com/SunkenInTime/weaver/pull/21), implementation `01c49e0` | [`styling/N3-radii-borders`](https://github.com/SunkenInTime/native/pull/9) at `e26de471a25b0293d270cf31517eb6e5c6936b31` | complete, pushed, draft PRs open |
| 04 | [`styling/04-palette`](https://github.com/SunkenInTime/weaver/pull/22), implementation `4d0c4a8` | none | complete, pushed, draft PR open |
| 05 / N4 | [`styling/05-text-pack`](https://github.com/SunkenInTime/weaver/pull/23), implementation `f9693ae` | [`styling/N4-text`](https://github.com/SunkenInTime/native/pull/10) at `32735626d8ba369e53bedd22a1e3dab46b2c08aa` | complete, pushed, draft PRs open |
| 06 / N5 | [`styling/06-shadows`](https://github.com/SunkenInTime/weaver/pull/24), implementation `5fff1ee` plus final test follow-up `9237c18` | [`styling/N5-shadows`](https://github.com/SunkenInTime/native/pull/11) at `b487d48b` (PR06 pins the shadow-complete `f8455262`; the later commit is the brief-authorized PR07 font seam) | complete, pushed, draft PRs open |
| 07 | [`styling/07-fonts`](https://github.com/SunkenInTime/weaver/pull/25), Native pin `8121bf6`, implementation `a18f4ac` plus extension edge-case `da5130d` | per-text selection follow-up in [N5](https://github.com/SunkenInTime/native/pull/11) at `b487d48b` | complete, pushed, draft PR open |
| 08 | [`styling/08-icons`](https://github.com/SunkenInTime/weaver/pull/26), implementation `6392b29` | none (rides N5's PR07 font seam) | complete, pushed, draft PR open |
| 09 / N6 | `styling/09-stack-overflow` | [`styling/N6-stack-overflow`](https://github.com/SunkenInTime/native/pull/12) at `9411bc45` | Native complete/pushed; Weaver in progress |
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
- Native N5 PR07 font follow-up `b487d48b`: focused canvas suite PASS in 43.2s with exact plain/paragraph registered-id projection; validate + stock suite PASS together in 89.6s; final widget-profile suite PASS in 94.2s. The face id rides the pre-existing bounded immediate-command slice, preserving the Widget size bound.
- Weaver 06: `npm test` PASS 34/34; `npm run typecheck` PASS; final runtime `zig build test -Dweb-layer=exclude -Dtrace=off` PASS in 7.8s; CLI build and `weaver check examples/styling-shadows` PASS; ReleaseFast runtime build PASS in 117.9s. Isolated dev smoke reached status `running` at 27s uptime with one startup, software/pixels presentation, and no exception/crash/restart line; isolated host/watchers and the temporary registry were removed.
- Weaver 07: `npm test` PASS 37/37 in 17.9s; `npm run typecheck` and `npm run build` PASS; final runtime `zig build test -Dweb-layer=exclude -Dtrace=off` PASS in 7.0s; CLI check/bundle PASS; ReleaseFast runtime build PASS in 72.6s. Pack/inspect produced artifact `f710de0373fe830e7fab90c774f9d472c98013a38d69b86e7aa2818d88f50dae` with 3 readable files/100119 bytes; isolated install preserved the 94800-byte font and 4475-byte OFL in source and `dist`. Dev stayed `running` at 37s uptime with one dev startup and no font/exception/crash/restart line; isolated host/watchers, install, archive, and temporary data were removed.
- Weaver 08: `npm test` PASS 39/39 in 21.1s; `npm run typecheck` PASS in 2.4s; SDK package dry-run includes the font/license/map; runtime `zig build test -Dweb-layer=exclude -Dtrace=off` PASS in 0.6s cached; ReleaseFast runtime build PASS in 68.2s; CLI check/bundle PASS. Pack/inspect produced artifact `da9c8fe7c3fdbe415ab7107d936cbf84a5673e3c195d996b36a4caac11a74bd9`; isolated install reconstructed the 26768-byte font and 3208-byte license in `dist`. Dev stayed `running` at 34s uptime with one dev startup and no font/exception/crash/restart line; temporary installation, host/watchers, archive, and data were removed.
- Native N6: focused canvas suite PASS in 58.7s; `zig build validate` PASS in 21.3s; stock suite PASS in 95.5s; widget-profile suite PASS in 71.3s. Exact tests cover the public stack clipping option, asymmetric emitted masks, render-plan propagation, reference corner pixels, packet JSON/version prose, and fingerprint changes. Draft PR: https://github.com/SunkenInTime/native/pull/12.

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
19. Native widget profile is the binding font budget: at most two registered faces and 512 KiB per face. `weaver check` enforces the same limits before bundle/pack so registration cannot fail later for a budget mismatch.
20. Root-adjacent `.ttf` and `.otf` are discovered as font assets. The bounded renderer requires `glyf`/`loca`/`hmtx` plus Unicode cmap format 4; OTF/CFF is rejected with an explicit TrueType-outline conversion instruction because accepting it would make reference and macOS rendering disagree.
21. Exact `font-[file-stem]` always selects that face. A terminal `-Light/-Regular/-Medium/-Semibold/-Bold` (or underscore) additionally creates a family alias, and the closest registered weight wins. With one custom face every requested weight deliberately degrades to that face; built-in sans keeps Native's three real rungs and mono its single face.
22. Font files and adjacent licenses reuse the existing ordinary-source `.weave` and `dist` asset paths; no opaque font sub-format or duplicate archive channel is introduced.
23. The binding Lucide source is `lucide-static@1.25.0` (ISC; npm tarball SHA-1 `d44930d6e5815faace63d9fd9c46c0cadabaaae8`). Its 843668-byte font exceeds the 512 KiB face cap, so PR08 freezes an explicit alphabetized subset of 79 common widget/media/navigation/status names; the generated face is 26768 bytes and includes the upstream Lucide/Feather license.
24. Because PR08 is not authorized to change Native and rides PR07's two-face registry, a widget containing `<icon>` reserves id 64 for `WeaverLucide` and may bundle one custom face at id 65. Widgets with no icon retain both custom-face slots.
25. Icon names must be literal JSX attribute strings (including literal string expressions) so `weaver check` can prove membership and issue a deterministic nearest-name fix-it. Dynamic names are rejected even when their TypeScript type is narrowed; components can instead choose among statically authored icon nodes.
26. The Native render packet can carry one rounded clip per command. Nested clips that contain one another retain the tighter rounded mask; partially overlapping rounded clips preserve their exact rectangular intersection and drop only the unrepresentable corner arcs rather than inventing a lens representation.
27. Under a non-uniform or rotated affine transform, circular clip radii scale by the smaller finite axis magnitude. This keeps the flattened command mask circular and bounded; an exact elliptical-corner representation would require a broader wire change outside N6.

## UNVERIFIED / BLOCKED

- `UNVERIFIED (needs Mac)`: N1 shared-layout behavior on the macOS reference and Metal presentation paths. Evidence available now: platform-neutral Native Zig suites pass on Windows; await PR CI for compile gates and Mac hardware for physical pixels.
- `BLOCKED (unrelated Native fast gate)`: `scripts/gate.sh fast origin/weaver-main` fails `examples-native` because five existing example switches omit the already-present `runtime.api.Event.window_frame` member. Evidence: `capabilities`, `native-panels`, `command-app`, `native-shell`, and `gpu-components` compile errors; changed canvas suite and the required stock/profile suites pass.
- The same unrelated `examples-native` failure reproduced for N2 against N1; all other affected fast-gate groups passed.
- The same unrelated `examples-native` failure reproduced for N3 against N2; zig-test, validate, frontend examples, and mobile examples passed.
- `UNVERIFIED (needs Mac)`: N3 asymmetric surface pixels. Evidence available now: Native exact display-list radius/stroke assertions and all Windows stock/profile suites pass; physical macOS output remains unobserved.
- `UNVERIFIED (needs Mac)`: N4 CoreText kern and monospaced-number feature application, plus physical clamp/alignment pixels. Evidence available now: Objective-C packet wiring, platform-neutral exact tests, static validation, and both full Windows suites pass; macOS compilation/physical output awaits CI/hardware.
- `BLOCKED (unrelated Native fast gate)`: N4 fast gate reproduces the same five `examples-native` exhaustive-switch failures for the pre-existing `window_frame` event. The N4 changed canvas tests, validate, frontend, and mobile groups pass; macOS-only CEF link validation is skipped on Windows.
- `UNVERIFIED (needs Mac)`: N5 AppKit v5 packet decoding, inverse-path inset clipping, and `NSShadow` text pixels. Evidence available now: packet/prose ratchets, exact platform-neutral tests, static validation, and both Windows full suites pass; Objective-C compilation and physical pixels await macOS CI/hardware.
- `UNVERIFIED (needs Mac)`: PR07 registered-font selection through CoreText/AppKit. Evidence available now: SFNT validation, bounded registration, exact runtime resolution/projection tests, Native stock/profile suites, and the Windows live example pass; macOS compilation and physical glyph pixels await CI/hardware.
- `UNVERIFIED (needs Mac)`: PR08 Lucide subset selection and physical glyph pixels through CoreText/AppKit. Evidence available now: exact name/codepoint lowering, copied-asset equality, bounded registration tests, Native stock/profile suites, and the Windows live example pass; macOS physical output awaits CI/hardware.
- `BLOCKED (unrelated Native fast gate)`: N5 fast gate against N4 passes zig-test (34s), validate, frontend examples, and mobile examples (44s), but the same five `examples-native` switches omit pre-existing `window_frame`. Apple-Silicon benchmarks and macOS CEF link are skipped on Windows.
- `RESOLVED during N5`: the first final full-suite pass found the schema ratchet and macOS decoder prose still naming v4 after the v5 packet change; both were updated and pushed. One intervening Windows run also hit transient `error.Unexpected` while creating an iOS test asset directory; an immediate clean rerun passed in 25.2s.
- `RESOLVED during PR03`: the first `weaver dev` attempt used a stale runtime after a parallel ReleaseFast build was canceled by the stale-CLI check failure, causing three `unsupported property` crash restarts. An explicit runtime rebuild followed by a fresh 15s smoke produced one startup and no exception/restart. Both outcomes are in PR21 evidence.
- `UNVERIFIED (needs Mac)`: N6 AppKit wire-v6 decoding and physical asymmetric rounded stack pixels. Evidence available now: version/prose ratchets, direct and raster-cache host paths, exact reference pixels, static validation, and both Windows full suites pass; Objective-C compilation and physical output await macOS CI/hardware.
- `BLOCKED (unrelated Native fast gate)`: N6 fast gate passes zig-test (29s), validate (1s), frontend examples (6s), and mobile examples (36s), but `examples-native` fails after 121s in the same five pre-existing exhaustive switches that omit `Event.window_frame`; N6 changes neither those examples nor `src/runtime/api.zig`. Total gate time: 193.3s.

## Cleanup state

- Work is confined to `E:\Projects\weaver-styling-run` and its submodule.
- No default branch was changed or merged; no frozen `weaver-fork*` branch was extended.
- No Weaver dev process is currently running.
- Isolated PR 01 dev data under `%TEMP%\weaver-styling-run-pr01` was removed after shutdown.
- PR06 isolated data under `.dev-smoke-pr06` was removed after `weaver down`; all clone-owned dev watchers and their esbuild helpers were stopped. The cleanup also removed one stale PR05 spacing watcher discovered during the audit.
- PR07 isolated install/dev data under `.dev-smoke-pr07` and its temporary `.weave` archive were removed after uninstall and `weaver down`; the final process audit found no clone-owned runtime, host, watcher, or esbuild process.
- PR08 isolated install/dev data under `.dev-smoke-pr08` and its temporary `.weave` archive were removed after uninstall and `weaver down`; the final process audit found no clone-owned runtime, host, watcher, or esbuild process.

## Next executable task

Implement Weaver `styling/09-stack-overflow` on the pinned Native N6: add `<stack>`, `overflow-hidden`, compiler accept/reject coverage, exact runtime projection tests, example/live smoke, and all required Weaver gates.
