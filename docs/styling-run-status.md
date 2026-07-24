# Styling breadth run status

Updated: 2026-07-24 (Windows 11, interaction-state extension)

## 2026-07-23 path-icon redesign

- PR08 was rewritten in place: `<icon>` is lowered at bundle time to
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
- Assumption: Weaver's retained tree heap-owns the rare normalized string per
  icon node. The 128-node table contains only a slice, not an inline 8 KiB
  array; replacement, subtree removal, rejected hot swap, successful hot-swap
  move, and process teardown all release their owned storage.
- Assumption: Lucide named icons always use the upstream `0 0 24 24` view box,
  two-unit round stroke, and current text color. Raw `d` icons default to fill;
  a positive `stroke` prop selects round stroked rendering.
- Assumption: Noro's solid controls will use the exact 24-unit Rainmeter paths
  from upstream `NoroPlayer/Player.ini`; this belongs to PR13 and must preserve
  the radii introduced by `4241b12`.

### Path-icon completion evidence

- Final post-repair heads before this evidence follow-up: Weaver PR08
  `b26e362`, PR09 `3e85fc6`, PR10 `c1ecb1c`, PR11 `8b76dfa`, PR12
  `9c27d23`, PR13 `60c6976`; Native N5 `31d5710b`, N6 `4981f66f`,
  N7 `de432244`, N8 `85f5dbe5`.
- Native N5-N8 each PASS full stock `zig build test` and full
  `zig build test -Dwidget-profile=true` at the exact pushed head. The first
  N5 stock attempt was environment-invalid because Git's `test` helper was
  absent from `PATH`; restoring the documented Git `usr\bin` path made both
  N5 suites pass.
- Weaver PR08-PR13 each PASS `npm test`, `npm run typecheck`, runtime
  `zig build test -Dweb-layer=exclude -Dtrace=off`, and `npm run
  audit:release`. Test counts are 45/47/48/51/53/53. The release-audit sweep
  also PASSes all 13 Weaver heads at their exact historical/restacked pins.
- The first PR08 Apple-silicon session rollup exposed a Clock provider stack
  overflow. Returning icon-free source byte-for-byte at `b26fee23` was a valid
  no-op ratchet but did not cure the repeated session failure. The true cause
  was Weaver's retained `Node` carrying an inline 8 KiB `icon_path` array:
  128 nodes inflated every `Tree` by roughly 1 MiB and exhausted the smaller
  macOS callback stack. PR08 `7c8dd9f` moves rare strings to bounded heap
  storage with complete ownership cleanup; `b26e362` adds a stack-wide node
  size ratchet. A Windows Clock provider ran for 39 seconds and applied a
  preserved-state hot swap with no exception before the complete local matrix
  passed on every descendant.
- Noro visual gate PASS, opened at original resolution:
  `E:\tmp\weaver-path-icons-20260723\noro-path-icons-visual-gate.png`.
  The exact upstream solid prev/pause/next shapes are centered at 28x28, the
  button corner radii remain 8.33/37.5, cover/overlays/rim/record dot/grille
  remain correct, and the Cozette row reads `00:06 / LET IT GO / 03:58 AM`.
  The authoritative reference was fetched and opened at
  `E:\tmp\weaver-path-icons-20260723\noro-reference-preview.png`.
- Styling Icons visual gate PASS, opened at original resolution:
  `E:\tmp\weaver-path-icons-20260723\styling-icons-visual-gate-final2.png`.
  Assorted full-catalog names, currentColor, custom fill/stroke, and
  16/24/32/40 geometry render crisply. The first capture was rejected because
  an unrelated desktop widget overlapped the top-right anchor; only the
  run-owned HWND was moved and redrawn for the accepted capture.
- Installed Noro idle gate PASS: after a 129-second settle, PID 32920 advanced
  `0.000 ms` TotalProcessorTime over `60.011 s` (62.5 ms before and after,
  two threads). The isolated installation was uninstalled and its host stopped.
- Final post-storage-repair installed rerun PASS: after a 141-second settle,
  PID 5408 advanced `15.625 ms` over `60.003 s` (125.000 ms to 140.625 ms,
  five threads), exactly one Windows accounting quantum and below the
  `<=30 ms` acceptance bound. The isolated installation was uninstalled and
  its host stopped.
- Final pre-ledger CI rollups PASS all four jobs (Windows gate, Intel
  headless, Apple-silicon headless, Apple-silicon session): PR08 run
  `30039910723`, PR09 `30039923141`, PR10 `30039925329`, PR11
  `30039927921`, PR12 `30039931561`, PR13 `30040382089`. Native PR11-14
  expose no configured checks; their exact stock/widget-profile suites pass
  locally.

## Stack map

| Layer | Weaver | Native SDK fork | State |
|---|---|---|---|
| 01 / N1 | [`styling/01-spacing-sizing`](https://github.com/SunkenInTime/weaver/pull/19) at `5ca71974` | [`styling/N1-layout-spacing`](https://github.com/SunkenInTime/native/pull/7) at `0e16af24` | complete, pushed, draft PRs open |
| 02 / N2 | [`styling/02-flex-completeness`](https://github.com/SunkenInTime/weaver/pull/20) at `59ab68b1` | [`styling/N2-flex`](https://github.com/SunkenInTime/native/pull/8) at `d6389750` | complete, pushed, draft PRs open |
| 03 / N3 | [`styling/03-radii-borders`](https://github.com/SunkenInTime/weaver/pull/21) at `4bdeaa17` | [`styling/N3-radii-borders`](https://github.com/SunkenInTime/native/pull/9) at `d903766c` | complete, pushed, draft PRs open |
| 04 | [`styling/04-palette`](https://github.com/SunkenInTime/weaver/pull/22) at `954d86dc` | none; retains N3 `d903766c` | complete, pushed, draft PR open |
| 05 / N4 | [`styling/05-text-pack`](https://github.com/SunkenInTime/weaver/pull/23) at `75a91fd2` | [`styling/N4-text`](https://github.com/SunkenInTime/native/pull/10) at `aa6eacd5` | complete, pushed, draft PRs open |
| 06 / N5 | [`styling/06-shadows`](https://github.com/SunkenInTime/weaver/pull/24) at `8d1d8042` | pre-path N5 pin `eb6416df` | complete, pushed, draft PR open |
| 07 | [`styling/07-fonts`](https://github.com/SunkenInTime/weaver/pull/25) at `aaa1353a` | rides pre-path N5 `eb6416df` | complete, pushed, draft PR open |
| 08 / N5 | [`styling/08-icons`](https://github.com/SunkenInTime/weaver/pull/26) at `b26e362` | [`styling/N5-shadows`](https://github.com/SunkenInTime/native/pull/11) at `31d5710b` | complete, pushed, draft PRs open; path-icon redesign |
| 09 / N6 | [`styling/09-stack-overflow`](https://github.com/SunkenInTime/weaver/pull/27) at `3e85fc6` | [`styling/N6-stack-overflow`](https://github.com/SunkenInTime/native/pull/12) at `4981f66f` | complete, pushed, draft PRs open |
| 10 / N7 | [`styling/10-image-v2`](https://github.com/SunkenInTime/weaver/pull/28) at `c1ecb1c` | [`styling/N7-image-v2`](https://github.com/SunkenInTime/native/pull/13) at `de432244` | complete, pushed, draft PRs open |
| 11 / N8 | [`styling/11-interaction`](https://github.com/SunkenInTime/weaver/pull/29) at `2f416b9` | [`styling/N8-interaction`](https://github.com/SunkenInTime/native/pull/14) at `c61d3518` | complete, pushed, draft PRs open |
| 12 | [`styling/12-showcase`](https://github.com/SunkenInTime/weaver/pull/30) at `a4041cd` | rides N8 `c61d3518` | complete, pushed, draft PR open |
| 13 | [`styling/13-noro-shell`](https://github.com/SunkenInTime/weaver/pull/31), pressed-state implementation `012b3dc` plus this evidence ledger | rides N8 `c61d3518` | complete, pushed, draft PR open; code-head CI pending at ledger authoring |

## Completed gates

### Independent-review repair rerun (final heads above)

- Weaver PR01-PR12: every head passed `npm test`, `npm run typecheck`, `runtime/ zig build test -Dweb-layer=exclude -Dtrace=off`, and `npm run audit:release`. Node suites ranged from 25 to 51 tests; runtime suites all passed with the expected one platform skip. Exact per-head durations are retained in the run evidence log.
- Native N1-N8: every head passed focused `zig build test-canvas -Dwidget-profile=true`, full stock `zig build test`, and full `zig build test -Dwidget-profile=true`. Focused durations were 34.9-47.4s; stock 74.1-110.4s; widget profile 54.0-103.8s.
- All 12 PR examples were rebuilt ReleaseFast, passed `weaver check`, reached live status `running` for 20s, emitted no exception/crash/backoff/restart line, and left zero clone-owned host/widget processes. PR01-PR05 used `styling-spacing`; PR06-PR12 used their layer example, ending with `retro-player-shell`.
- The final retro-player capture shows the overlay elapsed-time text at the far right. `widget.json` registers `GeistPixel-Square.ttf` as id 65, the exact-stem resolver selects it, and the live headline is rendered with `font-[GeistPixel-Square]`.
- Resolved rerun defects: every branch-local release audit now names its exact restacked gitlink; PR04 no longer reintroduces the missing `p-[Npx]` return; N8 casts each interaction-presence bit to `usize` before addition, so simultaneous hover and pressed metadata cannot overflow.

- Virgin Weaver `master` (`origin/master`): `npm test` PASS 22/22; `npm run typecheck` PASS; `runtime/ zig build test -Dweb-layer=exclude -Dtrace=off` PASS.
- Native N1 focused: `zig build test-canvas -Dwidget-profile=true` PASS.
- Native N1 required full suites: `zig build test` PASS in 79.22s; `zig build test -Dwidget-profile=true` PASS in 57.43s.
- Native N2 focused canvas suite PASS; stock suite PASS in 100.46s; widget-profile suite PASS in 44.63s.
- Weaver 01: `npm test` PASS 25/25; `npm run typecheck` PASS; `runtime/ zig build test -Dweb-layer=exclude -Dtrace=off` PASS.
- Weaver 01 example: `weaver check examples/styling-spacing` PASS; release runtime and host builds PASS; `weaver dev examples/styling-spacing` stayed alive for 15s with status `running`, software backend, 12s runtime uptime, and no crash/restart line. `weaver down` left zero run-owned Weaver processes.
- Weaver 02: `npm test` PASS 26/26; `npm run typecheck` PASS; runtime Zig tests PASS; updated example check and ReleaseFast runtime build PASS. Dev stayed alive 15s, status `running` with 12s uptime, one startup/no restart, and cleanup left zero processes/data.
- Native N3 focused canvas suite PASS in 35.6s; stock suite PASS in 82.03s; widget-profile suite PASS in 51.61s. Exact commands assert independent corner radii and explicit stroke width/color.
- Native N3 Apple-silicon CI repair: the per-corner fields now use an in-band unset sentinel and a new `WidgetStyle <= 156 bytes` ratchet without changing finite or negative-radius semantics. Focused profile canvas PASS in 41.2s; validate PASS in 0.5s; stock PASS in 31.4s; widget-profile PASS in 57.7s. The first stock attempt was not a verdict because Git `usr/bin` was absent from `PATH`; after restoring the documented PATH, the rerun passed.
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
- Weaver 09: `npm test` PASS 41/41 in 19.9s; `npm run typecheck` PASS in 2.4s; example TypeScript, CLI build/check/bundle, and `git diff --check` PASS; runtime `zig build test -Dweb-layer=exclude -Dtrace=off` PASS in 22.1s; ReleaseFast runtime build PASS in 63.3s. Isolated dev smoke reached `running` at 52s uptime with one startup and software/pixels presentation, with no exception/crash/restart line; `weaver down`, watcher shutdown, and final process audit left no clone-owned process.
- Native N7: focused canvas suite PASS in 55.8s; `zig build validate` PASS in 10.4s; stock suite PASS in 95.8s; widget-profile suite PASS in 52.2s. Exact tests cover native-size 2x1 tiling across a 5x2 destination, public UI propagation, asymmetric image masks, packet JSON/wire-v7, and fingerprint changes. Draft PR: https://github.com/SunkenInTime/native/pull/13.
- Weaver 10: `npm test` PASS 42/42 in 22.1s; `npm run typecheck` PASS in 4.0s; example TypeScript/check/bundle and `git diff --check` PASS; runtime `zig build test -Dweb-layer=exclude -Dtrace=off` PASS in 25.8s; ReleaseFast runtime build PASS in 68.7s. Isolated `weaver dev examples/styling-images` reached `running` at 55s uptime with one startup, software/pixels presentation, and no exception/crash/restart line; shutdown and the broad process audit left no clone-owned process.
- Release-audit repair: PR01 through PR10 now each require their branch's exact Native gitlink. A branch-by-branch checkout, recursive submodule update, and `npm run audit:release` sweep passed all ten heads (`e7648949`, `457c2dd9`, `bb20a1f5`, `85cda5d7`, `0d36b403`, `b96b72f8`, `65aff3ea`, `e66ea8cd`, `16e49390`, `8669cfae`).
- Native N8: focused profile canvas suite PASS in 70.2s after the target-id follow-up; `zig build validate` PASS in 38.4s; stock suite PASS in 46.0s; widget-profile suite PASS in 59.6s. Exact tests cover retained hover/pressed channel resolution, pressed precedence, target/local geometry, click count, double/right dispatch, invalidation, and hostile arena bounds. Draft PR: https://github.com/SunkenInTime/native/pull/14.
- Weaver 11: `npm test` PASS 45/45 in 27.4s; `npm run typecheck` PASS in 2.8s; final runtime `zig build test -Dweb-layer=exclude -Dtrace=off` PASS in 10.7s; ReleaseFast runtime test PASS in 60.6s; CLI build and example TypeScript/check/bundle PASS. Corrected isolated `weaver dev examples/styling-interaction` reached `running` at 67s uptime with one startup, software/pixels presentation, and zero exception/crash/restart lines; shutdown and broad process audit left no clone-owned process.
- Weaver 12: final post-restack `npm test` PASS 47/47 in 21.8s; `npm run typecheck` PASS in 2.4s; `npm run build` PASS in 0.5s; example TypeScript PASS in 3.0s, check PASS in 2.4s, bundle PASS in 2.5s; release audit PASS in 0.7s at Native `8aae6aa2`; runtime Debug `zig build test -Dweb-layer=exclude -Dtrace=off` PASS in 18.9s and ReleaseFast PASS in 18.4s; consolidated contract test PASS 2/2 and its parser is CRLF/LF-agnostic; conjure skill validation PASS. A fresh isolated live run reached 75s uptime with one startup, software/pixels presentation, and zero error/restart lines. Physical capture was visually accepted, and the matched-window A/B is recorded in `docs/styling-breadth-results.md`.
- Final N3 ARM-arena repair at `d4e8ac33`: N2 `Widget` is 712 bytes and N3 is 728 bytes, explaining the 16-byte-per-copy CI growth. Four f32 corner overrides and all limits remain unchanged; Markdown block/list/table node buffers now pre-size from safe source-line upper bounds instead of eagerly reserving 64 multi-KiB `Ui.Node` values for short inputs. Focused canvas PASS 34.3s; `validate` PASS 10.5s; stock PASS 103.3s; widget-profile PASS 62.7s; the hostile bound is unchanged.
- Final N4 arena repair at `9dc298d0`: six text-only values moved from common `Widget` fields into one `WidgetTextStyle` record in the existing bounded `immediate_commands` side channel. Default widgets allocate nothing; N5 font/shadow and N8 hover/pressed metadata coexist in the same slice. An exact test pins `@sizeOf(Widget) == 728` (the N3 size). N4 `validate` PASS 11.7s, focused canvas PASS 39.0s/816 tests (813 pass, 2 skip), stock PASS 103.3s, widget-profile PASS 77.3s before the inherited N3 allocation-only restack.
- Final Native restack verification: N5 `validate` 20.2s, stock 76.4s, profile 64.8s (focused rerun PASS 44.8s); N6 `validate` 20.2s, focused 34.7s, stock 77.1s, profile 63.8s; N7 `validate` 22.1s, focused 34.0s, stock 75.7s, profile 71.7s; N8 `validate` 10.5s, stock 75.1s, profile 82.4s (focused rerun PASS 45.4s). All exact pushed heads were clean.
- Final Weaver restack verification: `audit:release` PASS on all 12 exact heads (0.5-0.9s each). Heads 05-12 respectively passed `npm test` in 15.1/13.6/18.2/21.2/22.9/20.6/21.9/21.0s, `npm run typecheck` in 3.6/2.4/3.0/2.4/1.9/2.2/2.1/2.5s, and runtime `zig build test -Dweb-layer=exclude -Dtrace=off` in 24.2/15.3/5.5/0.8/17.7/17.6/7.8/0.6s. PR12 build, example TypeScript, check, and bundle PASS in a separate final run.
- Final PR12 live rerun at Native `709989d2`: fresh isolated host reached `running` at 67s uptime, software/pixels, 0.5% reported CPU and 28.209 MiB private memory, with one startup and zero stderr/error/restart lines. `weaverd`, watcher, and widget exited; all three PIDs were absent and the isolated data root was removed.
- Final inherited-N3 aggregate rerun: Native N8 `80e74357` focused PASS 46.1s, `validate` PASS 11.4s, stock PASS 66.5s, widget-profile PASS 59.2s. Weaver PR03 `npm test`/typecheck/runtime PASS 11.7s/1.8s/18.1s; PR12 PASS 21.3s/2.1s/19.4s. A fresh all-12-head release-audit sweep passes at exact pins `1a02e159`, `83a92a0d`, `d4e8ac33`, `d4e8ac33`, `9dc298d0`, `0fadeee5`, `d744f423`, `d744f423`, `b9ca6cd1`, `adc097c0`, `80e74357`, `80e74357`.
- Independent-review final GitHub CI rollup: Weaver PR19-30 PASS the Windows gate, Intel headless, Apple-silicon headless, and Apple-silicon session jobs at the restacked review heads. PR28's first Intel attempt failed in the unchanged loopback HTTPS setup when `waitForTestPort` read an empty temporary port file (`error.InvalidCharacter`); rerunning that failed job on the identical `a0d567b` head passed the network step and the complete Intel job, after which the dependent Apple-silicon session also passed. No styling code or test changed for the rerun. Native PR7-14 report no configured GitHub checks; their focused/stock/widget-profile suites pass locally at every exact pushed head.

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
23. The binding Lucide source is `lucide-static@1.26.0` (ISC; 1,749 names; npm tarball SHA-1 `cdaec64ebb9ba10d9ce0fc065184b9dde3eb992d`; integrity `sha512-6yCpa2ONICjlE19BuneIi75ASd9cCZhqJlzhAlQBi+99m2aZd2cNzxFVbDgPu7JLBZR2uDYO/EpLYtnhGw5Niw==`). PR08 resolves names to SVG geometry at bundle time and embeds only paths used by the widget. The Lucide/Feather license remains; the TTF subset and codepoint map are deleted.
24. Path icons reserve no font face. Native's two registered-face slots remain available to custom fonts. Normalized icon data uses its own 8 KiB per-node budget and the widget profile permits 2,048 aggregate path elements so one contract-valid icon can always be retained without growing every `Widget`.
25. Icon names and custom path data must be literal JSX attribute strings (including literal string expressions) so `weaver check` can normalize, budget, prove membership, and issue deterministic full-catalog nearest-name fix-its. Dynamic values are rejected even when their TypeScript type is narrowed; components can instead choose among statically authored icon nodes.
26. The Native render packet can carry one rounded clip per command. Nested clips that contain one another retain the tighter rounded mask; partially overlapping rounded clips preserve their exact rectangular intersection and drop only the unrepresentable corner arcs rather than inventing a lens representation.
27. Under a non-uniform or rotated affine transform, circular clip radii scale by the smaller finite axis magnitude. This keeps the flattened command mask circular and bounded; an exact elliptical-corner representation would require a broader wire change outside N6.
28. `<stack>` remains a layout-only overlay primitive, matching Native's stack kind: its own radius shapes `overflow-hidden`, while a visible backdrop/border is authored as the first full-size child `<panel>`. This preserves child-order painting and avoids silently changing stack identity into a panel.
29. Image `tile` ignores `fit` and repeats the selected source rectangle at its native logical-pixel dimensions, anchored at the normalized destination's top-left. Sampling and the destination's asymmetric rounded mask still apply.
30. The AppKit host caps one image command at 65,536 repeated tile draws; a pathological command beyond that refuses packet presentation through the existing fallback path instead of hanging the host.
31. Image `fit` and `tile` are typed `<image>` attributes rather than pseudo-CSS utilities; the existing `rounded-*` compiler surface is the single source of image mask radii. Consequently PR10 adds prop acceptance/rejection and exact projection tests but no duplicate fit/tile class family.
32. Native N8 stores rare hover/pressed style records in the existing immediate-command slice so the common Widget allocation and hostile profile budget remain unchanged. Disabled widgets ignore authored variants, and pressed wins over hover when both retained state bits are true.
33. Native's historical `on_hold` message and the new typed `on_right_press_event` share the compact secondary-gesture slot required to keep the arena-resident UI Node bounded. If both are authored, the dedicated right-press handler wins; with no right handler, right press retains the `on_hold` fallback.
34. `WidgetPressEvent` carries the Native structural target id in addition to geometry. Weaver resolves it against at most 128 retained nodes using the same public global-id function, then exposes only `{x,y,u,v}` to JS; this avoids per-node callback closures and keeps the target id out of the widget API.
35. `pressed:` is the brief's explicit state-prefix spelling even though Tailwind CSS calls its nearest built-in pseudo-state `active:`. Only the brief's four channels are accepted, with the underlying color and opacity utility semantics kept exact; unsupported state channels remain loud check-time errors.
36. Normalized press coordinates are clamped to 0–1, with zero-size axes yielding zero, so the API keeps the promised normalized range even for degenerate or edge hit geometry.

37. PR12 uses fixed display strings and no provider, interval, animated canvas, fetch, or state loop. The clock and playback values are intentionally fake so the acceptance anchor preserves idle-zero.
38. The cover art and Geist Pixel font are reused from the repository's Native deck/font assets. The grille is a built-in image-generator output; generator-only PNG metadata was stripped without changing pixels, and the generated canvas plus cover were normalized to 256×256 to satisfy the widget-profile 256 KiB decoded-image bound.
39. `<stack>` is layout-only, so the showcase paints border/shadow on its first image child rather than the stack itself. The first physical capture exposed this contract mistake; moving paint to the child restored the cover and every later overlay.
40. The required A/B compares different widgets exactly as the brief requests. Ten host `status.json` snapshots were taken two seconds apart on the same Windows machine, software/pixels path, release binaries, isolated data roots, and one widget at a time; the result is observational and not a causal per-layer performance claim.
41. The computer-control plugin could not initialize because its native pipe was unavailable. Physical evidence therefore uses Win32 `PrintWindow` against each real Native widget window, followed by direct visual inspection of both PNGs.
42. The generated texture's first two encoded forms exceeded the source-stream limit, and its fixed 1254×1254 canvas plus the 512×512 cover exceeded the widget-profile decoded-image limit. The narrowest resolution was local 256×256 normalization; final check/bundle/live registration is clean.
43. Per-corner Native style overrides use negative infinity as an in-band unset sentinel. Every finite value, including a negative author value that clamps to zero, remains semantically distinct; this reduces the common `WidgetStyle` from the original optional-corner design's 172 bytes to 156 bytes without weakening the hostile-arena test.
44. N4 text styling is rare retained metadata, not common widget shape: a non-default text leaf gets one `WidgetTextStyle` command record, while default text and every non-text widget retain the N3 728-byte `Widget` and allocate no metadata. Later font, shadow, hover, and pressed records share that bounded slice and preserve authored order independently of drawing commands.
45. The N3 ARM regression is repaired by allocation accuracy rather than a larger hostile bound or lossy radius storage: source-line counts are safe upper bounds because every parsed block/list item/table row consumes at least one source line. Capacity caps and truncation behavior remain identical, while short containers no longer reserve their full 64-node maximum.
46. Numeric utilities use 1,000,000 logical units as the explicit absurd-value ceiling. This is far above the bounded widget surface while preventing finite exponential literals from becoming unusable layout magnitudes; non-finite values are always rejected.
47. Native preserves backward compatibility for direct callers that historically used positive zero as an unbounded maximum by encoding Weaver's explicit `max-w-0`/`max-h-0` as negative zero internally. Preferred width/height presence is carried in the existing packed layout flags, so authored zero is distinct from unset without growing `Widget`.
48. The lowered-budget check expands discoverable local JSX component return roots and conservatively checks each static root. Dynamic loop multiplicity and opaque `props.children` cannot be proven by the TypeScript AST; those cases remain bounded by the unchanged Native runtime limits, while every statically expressible painted row/column contributes its real extra node/depth.
49. D3D supports the current v7 solid shape/line subset, including per-corner rounded rectangles. Current-layout commands requiring rounded command clips, gradients, text, effects, or images deliberately return `false` to the existing per-command CPU fallback rather than being approximated or causing the whole GPU-backed widget to silently demote.
50. The single observed `night-bloom.jpg` failure did not reproduce in twelve isolated launches, and history proves the WIC decoder and decoded-image budget were unchanged by the review-fix commits. The narrow assumption is a transient failure in the one-shot WIC RGBA object graph; N7 now retries with a fresh decoder using Windows-native BGRA conversion and swaps channels back to straight RGBA.
51. The earlier capture-only GeistPixel claim is withdrawn as insufficient. An exact combined-metadata test exposed `@intFromBool` addition being inferred as `u1`: two rare commands overflowed in Debug and wrapped in ReleaseFast. PR06 widens every term to `usize`; PR07 proves the exact headline retains text style, text shadow, and font id 65; Native N5 renders the exact string both ways and measures 10,625 differing pixels.
52. The idle acceptance measurement used the production dev listener plus an independent `fs.watch` process that sends the identical loopback notification as `weaver dev`. A second full CLI/host instance could not be isolated because the already-running user host owns machine-global control objects; the watcher process remained alive for the complete sample and made no source change.
53. Windows reports process CPU time in 15.625 ms accounting quanta on this machine. The final 60,006.731 ms sample advanced by exactly one quantum (15.625 ms), which is recorded as scheduler/accounting noise rather than weakening the idle-zero contract.

## Three-defect follow-up (2026-07-22)

- JPEG / Native N7: production WIC decode moved into a directly testable source unit, metadata caching changed from on-demand to on-load, and a failed RGBA object graph is discarded before a fresh BGRA decode. `test-windows-image-decoder` passes on a real 512x512 baseline JPEG whose RGBA output is exactly the stock 1 MiB image budget. The final 256x256 showcase asset registered without an error and is visibly present in the PID-targeted `PrintWindow` capture.
- Headline / Weaver PR06+PR07 and Native N5: widened rare-command counting fixes the lost text-shadow + registered-font pair. Weaver exact projection preserves line height 36, tracking 0.75, shadow blur 10, and font id 65. Native's deterministic reference renderer reports 10,625 differing pixels between GeistPixel-Square and built-in bold sans for `SECOND NATURE` at 30 px.
- Idle / Weaver PR01: removed the repeating 100 ms dev reload timer. A kernel-blocked loopback listener publishes `.weaver-dev-port`; the event-driven CLI watcher opens it once per successful unchanged-config rebuild and Native `requestFrame` schedules exactly one hot swap. ReleaseFast PID 51452 with watcher PID 46400 consumed 15.625 ms over 60,006.731 ms, one Windows scheduler/accounting quantum.
- Final local matrix: Weaver PR01-PR12 each pass `npm test`, `npm run typecheck`, runtime `zig build test -Dweb-layer=exclude -Dtrace=off`, and the exact-pin `npm run audit:release`. Native N5-N8 each pass full stock and `-Dwidget-profile=true`; N7's focused Windows JPEG decoder and N5's focused reference-renderer suite pass. The first resumed Native stock invocation failed only because POSIX `test` was absent from PowerShell `PATH`; with Git `usr/bin` restored, the unchanged stock/profile commands pass.
- Live: cover art visible; overlay time remains right-aligned; headline visibly uses the square pixel face after the combined-metadata fix; no `ImageDecodeFailed`, crash, or restart line appeared.
- Pushed CI rollup before the final docs-only commit: Weaver PR19-PR30 each passed all four checks (Windows gate, Intel headless, Apple-silicon headless, Apple-silicon session). Native PR7-PR14 expose no configured GitHub checks; their local matrix is the recorded evidence. Exact pushed heads: Weaver `5ca7197/59ab68b/4bdeaa1/954d86d/75a91fd/8d1d804/aaa1353/fa76fbc/8ccabdc/2950151/e368983/7b4cfe2`; Native `0e16af24/d6389750/d903766c/aa6eacd5/eb6416df/5cfe3e82/a9e576a3/b4329804`.

## UNVERIFIED / BLOCKED

- Independent-review final state: no confirmed finding remains unfixed or blocked. Physical macOS pixels remain `UNVERIFIED (needs Mac)`; the Intel and Apple-silicon headless jobs compile and exercise the macOS paths but are not physical-pixel evidence. Native PR7-14 remain `UNVERIFIED (no configured GitHub checks)` despite the complete local focused/stock/widget-profile matrix passing at every exact pushed head.

- `UNVERIFIED (historical diagnostic)`: the original JPEG failure did not log a WIC HRESULT and did not reproduce in twelve isolated launches of the same pre-fix binary, so the exact failing WIC stage cannot be recovered. Evidence: one retained runtime log has `ImageDecodeFailed`; source history shows neither the WIC decoder nor image budget changed in the review wave; the production retry and real-JPEG boundary test cover the only observed failure surface.

- `UNVERIFIED (needs Mac)`: N1 shared-layout behavior on the macOS reference and Metal presentation paths. Evidence available now: platform-neutral Native Zig suites pass on Windows; await PR CI for compile gates and Mac hardware for physical pixels.
- `BLOCKED (unrelated Native fast gate)`: `scripts/gate.sh fast origin/weaver-main` fails `examples-native` because five existing example switches omit the already-present `runtime.api.Event.window_frame` member. Evidence: `capabilities`, `native-panels`, `command-app`, `native-shell`, and `gpu-components` compile errors; changed canvas suite and the required stock/profile suites pass.
- The same unrelated `examples-native` failure reproduced for N2 against N1; all other affected fast-gate groups passed.
- The same unrelated `examples-native` failure reproduced for N3 against N2; zig-test, validate, frontend examples, and mobile examples passed.
- `UNVERIFIED (needs Mac)`: N3 asymmetric surface pixels. Evidence available now: Native exact display-list radius/stroke assertions and all Windows stock/profile suites pass; physical macOS output remains unobserved.
- `UNVERIFIED (needs Mac)`: N4 CoreText kern and monospaced-number feature application, plus physical clamp/alignment pixels. Evidence available now: Objective-C packet wiring, platform-neutral exact tests, static validation, and both full Windows suites pass; macOS compilation/physical output awaits CI/hardware.
- `BLOCKED (unrelated Native fast gate)`: N4 fast gate reproduces the same five `examples-native` exhaustive-switch failures for the pre-existing `window_frame` event. The N4 changed canvas tests, validate, frontend, and mobile groups pass; macOS-only CEF link validation is skipped on Windows.
- `UNVERIFIED (needs Mac)`: N5 AppKit v5 packet decoding, inverse-path inset clipping, and `NSShadow` text pixels. Evidence available now: packet/prose ratchets, exact platform-neutral tests, static validation, and both Windows full suites pass; Objective-C compilation and physical pixels await macOS CI/hardware.
- `UNVERIFIED (needs Mac)`: PR07 registered-font selection through CoreText/AppKit. Evidence available now: SFNT validation, bounded registration, exact runtime resolution/projection tests, Native stock/profile suites, and the Windows live example pass; macOS compilation and physical glyph pixels await CI/hardware.
- `UNVERIFIED (needs Mac)`: PR08 physical vector-path pixels through AppKit. Evidence available now: full-catalog bundle lowering, strict normalized-path parsing, exact reference pixels, Native stock/profile suites, and both Windows visual examples pass; macOS physical output awaits hardware.
- `BLOCKED (unrelated Native fast gate)`: N5 fast gate against N4 passes zig-test (34s), validate, frontend examples, and mobile examples (44s), but the same five `examples-native` switches omit pre-existing `window_frame`. Apple-Silicon benchmarks and macOS CEF link are skipped on Windows.
- `RESOLVED during N5`: the first final full-suite pass found the schema ratchet and macOS decoder prose still naming v4 after the v5 packet change; both were updated and pushed. One intervening Windows run also hit transient `error.Unexpected` while creating an iOS test asset directory; an immediate clean rerun passed in 25.2s.
- `RESOLVED during PR03`: the first `weaver dev` attempt used a stale runtime after a parallel ReleaseFast build was canceled by the stale-CLI check failure, causing three `unsupported property` crash restarts. An explicit runtime rebuild followed by a fresh 15s smoke produced one startup and no exception/restart. Both outcomes are in PR21 evidence.
- `UNVERIFIED (needs Mac)`: N6 AppKit wire-v6 decoding and physical asymmetric rounded stack pixels. Evidence available now: version/prose ratchets, direct and raster-cache host paths, exact reference pixels, static validation, and both Windows full suites pass; Objective-C compilation and physical output await macOS CI/hardware.
- `BLOCKED (unrelated Native fast gate)`: N6 fast gate passes zig-test (29s), validate (1s), frontend examples (6s), and mobile examples (36s), but `examples-native` fails after 121s in the same five pre-existing exhaustive switches that omit `Event.window_frame`; N6 changes neither those examples nor `src/runtime/api.zig`. Total gate time: 193.3s.
- `UNVERIFIED (needs Mac)`: Weaver 09 / Native N6 physical asymmetric rounded clipping. Evidence available now: exact reference pixels, retained projection assertions, AppKit decoder/source wiring, all Windows gates, a stable Windows software live run, and green PR27 Intel/Apple-silicon headless plus Apple-silicon session CI; physical output still requires Mac hardware.
- `UNVERIFIED (needs Mac)`: N7 wire-v7 image tiling and physical rounded image pixels. Evidence available now: exact reference tiling, UI/draw propagation, packet/version tests, static validation, and both Windows full suites pass; Objective-C compilation and physical output await macOS CI/hardware.
- `BLOCKED (unrelated Native fast gate)`: N7 fast gate passes zig-test (31s), validate (<1s), frontend examples (5s), and mobile examples (38s), but the same five `examples-native` switches omit `Event.window_frame`; `examples-native` failed after 99s and total gate time was 173.7s.
- `RESOLVED (stack release audit)`: PR27's first post-push CI run failed its Windows gate and both macOS headless jobs only at `npm run audit:release`: actual Native pin `9411bc45`, stale expected pin `91949e15`. No test or CI step was removed or weakened. The stack was rebased bottom-up so PR01–PR10 each require their own exact gitlink, and the ten-branch local audit sweep passed; GitHub reruns were triggered by the force-with-lease pushes.
- `UNVERIFIED (needs Mac)`: Weaver 10 / Native N7 physical cover/contain/tile and asymmetric image-mask pixels. Evidence available now: exact reference tiling, retained/wire projection assertions, AppKit decoder/source wiring, all Windows gates, and a stable Windows software live run; physical output still requires Mac hardware.
- `BLOCKED (unrelated Native fast gate)`: N8 fast gate against N7 passes zig-test (28s), validate (1s), frontend examples (8s), and mobile examples (53s), but `examples-native` fails after 155s in the same five unchanged exhaustive switches that omit pre-existing `Event.window_frame`; total gate time 245.1s. N8 changes neither those examples nor the runtime Event tag set.
- `UNVERIFIED (needs Mac)`: Weaver 11 / Native N8 physical hover/pressed pixels and macOS right-click delivery. Evidence available now: exact Native state/event tests, stock/profile suites, exact Weaver wire/projection tests, a stable Windows software live run, and green PR29 Intel/Apple-silicon headless plus Apple-silicon session CI; physical macOS pixels still await hardware.
- `RESOLVED during PR11`: the first live smoke used the prior runtime executable and produced three `unsupported property` crash-restarts. An explicit ReleaseFast runtime executable rebuild followed by a fresh isolated run reached 67s uptime with one startup and zero exception/crash/restart lines; the failed attempt was not accepted as evidence.
- `RESOLVED during PR12`: the initial 2.4 MiB generated grille caused three `StreamTooLong` crash-restarts. A metadata-stripped image-generator revision fit the source stream but exposed `ImageTooLarge`; normalizing both local images to 256×256 meets the widget-profile decoded-image budget. The final fresh run has one startup, software/pixels presentation, 75s observed uptime, and zero error/restart lines.
- `RESOLVED during PR12`: the first physical showcase frame omitted all stack children because border/shadow had been authored on the layout-only `<stack>`. The shipped example moves those channels to the first image child; the final capture visibly contains the cover, overlay labels, elapsed text, progress, grille, and controls.
- `UNVERIFIED (needs Mac)`: PR12 physical CoreText font/icon pixels, AppKit image/clip/tile output, and native state visuals. Evidence available now: final Windows physical capture, exact contract/compiler ratchet, prior Native platform-neutral suites, and stable software live run; macOS hardware remains unavailable.
- `RESOLVED`: Apple-silicon headless first failed PR03–PR11 at the unchanged hostile-markdown arena bound (observed 1,536,552–1,603,480 bytes versus 1,520,896). N3 keeps lossless f32 corner overrides but right-sizes capped Markdown node buffers from safe line-count upper bounds; N4 restores its common `Widget` to the 728-byte N3 shape by retaining text metadata in the existing rare-command slice. Neither the hostile bound nor a test/CI step changed. Every final Windows focused/stock/profile/runtime gate passes, and Apple-silicon headless CI passes on every final Weaver head PR21–PR30.
- `RESOLVED (unrelated transient CI)`: PR21 Intel headless initially failed twice in the unchanged `network.test.macOS HTTPS transport preserves policy, bounds, timeout, trust, and cancellation` setup path because `waitForTestPort` read an empty temporary port file and `parseInt` returned `error.InvalidCharacter`. The third attempt passed the complete Intel job without a styling-code or test change; PR21's Apple-silicon headless and session jobs also pass.
- `RESOLVED (unrelated transient CI)`: PR28 Intel headless initially failed the same unchanged loopback HTTPS setup because `waitForTestPort` read an empty temporary port file and `parseInt` returned `error.InvalidCharacter`. A failed-job rerun on the identical `a0d567b` head passed the previously failing network step, every downstream Native profile step, and the dependent Apple-silicon session; no code or test changed.

## Noro fidelity follow-up

- Native N7 root cause: `src/primitives/canvas/render.zig:460-489` replaced the
  active rounded radius whenever a nested image emitter pushed its own
  equal-bounds square clip. The screen stack and cover therefore shared the
  correct offset rectangle, but the child erased the ancestor's rounded mask.
  The equal-rectangle branch at lines 471-477 now intersects radii
  corner-by-corner with `maxRadii`; the exact padded fixed-height cover test is
  at `src/primitives/canvas/widget_builtin_tests.zig:364`.
- Native N7 idle repair: the Win32 host unconditionally armed a repeating
  16ms top-level `WM_TIMER` after window creation. That obsolete pump was the
  only continuing main-thread wake; the explicit `kRequestFrameMessage` and
  one-shot GPU emission scheduler already provide demand-driven delivery.
  `src/platform/windows/root.zig:1535` now ratchets that the repeating timer is
  absent while both demand paths remain.
- Native N7 gates at `64b89cf4`: stock `zig build test` PASS and
  `zig build test -Dwidget-profile=true` PASS. Native N8 at `98c943e3`:
  stock and widget-profile suites PASS.
- Weaver restack gates: PR10 `42682f0` PASS 47/47 Node tests, typecheck,
  runtime Zig tests, and release audit; PR11 `fc7353a` PASS 50/50 plus the
  same gates; PR12 `c065458` PASS 52/52 plus the same gates; PR13
  `bb65795` PASS 52/52, typecheck, CLI build, example TypeScript, check,
  bundle, exact-pin release audit, and runtime Zig tests.
- Release audit PASS across all 13 Weaver heads at exact pins:
  `0e16af24`, `d6389750`, `d903766c`, `d903766c`, `aa6eacd5`,
  `eb6416df`, `eb6416df`, `eb6416df`, `5cfe3e82`, `64b89cf4`,
  `98c943e3`, `98c943e3`, `98c943e3`.
- Mandatory physical capture:
  `E:\tmp\weaver-noro-pr13\noro-shell-visual-gate-final.png`, reopened with
  the image viewer at original resolution. PASS: art fills the rounded screen
  with no top/right bleed; 14px dark rim visible on all sides; overlay reads
  `00:06 / LET IT GO / 03:58 AM` in Cozette pixel glyphs; record dot is
  top-right inside the screen; 5% grille is subtle; all three Lucide icons are
  centered.
- Installed-mode idle acceptance after a two-minute settle: 0.000ms process
  CPU over 59.943s; confirmation 0.000ms over 60.002s. Dev registration was
  absent. The run-owned installation and PID 22008 were removed afterward.
- Final affected Weaver CI: PR28 run `29983968548`, PR29 run `29983969846`,
  PR30 run `29983972078`, and PR31 run `29984071014` all PASS the Windows
  gate, Intel headless, Apple-silicon headless, and Apple-silicon session
  jobs. Native PR13/PR14 have no configured checks; their full local stock and
  widget-profile suites pass at the exact pushed heads.
- Assumption: the pre-existing untracked `examples/noro-shell.weave` is a
  generated isolation archive, not review source (no other `.weave` archive is
  tracked). It was preserved as
  `E:\tmp\weaver-noro-pr13\noro-shell-start.weave`; the authored source,
  font, and assets are committed in PR31.

## Cleanup state

- Work is confined to `E:\Projects\weaver-styling-run` and its submodule.
- No default branch was changed or merged; no frozen `weaver-fork*` branch was extended.
- No Weaver dev process is currently running.
- Isolated PR 01 dev data under `%TEMP%\weaver-styling-run-pr01` was removed after shutdown.
- PR06 isolated data under `.dev-smoke-pr06` was removed after `weaver down`; all clone-owned dev watchers and their esbuild helpers were stopped. The cleanup also removed one stale PR05 spacing watcher discovered during the audit.
- PR07 isolated install/dev data under `.dev-smoke-pr07` and its temporary `.weave` archive were removed after uninstall and `weaver down`; the final process audit found no clone-owned runtime, host, watcher, or esbuild process.
- PR08 isolated install/dev data under `.dev-smoke-pr08` and its temporary `.weave` archive were removed after uninstall and `weaver down`; the final process audit found no clone-owned runtime, host, watcher, or esbuild process.
- Before PR09 smoke, a fresh audit found two stale clone-owned Node/esbuild watcher pairs for the PR07 and PR08 examples despite the earlier narrower audits; PIDs 20764/9468 and 44400/1928 were terminated. PR09 isolated data and generated output were removed after shutdown, and the final broad executable-path audit found no clone-owned runtime, host, watcher, or esbuild process.
- PR10 isolated data and generated output were removed after `weaver down`; the dev watcher and its esbuild helper were explicitly stopped, and the final broad executable-path audit found no clone-owned runtime, host, watcher, or esbuild process.
- PR11 isolated data and generated output were removed after `weaver down`; the dev watcher and esbuild helper were explicitly stopped, and the final broad executable-path audit found no clone-owned runtime, host, watcher, or esbuild process.
- PR12 baseline/showcase hosts, dev watchers, isolated data roots, diagnostic captures, logs, and the detached master worktree were removed after shutdown. A broad process audit found no clone-owned runtime, host, watcher, or esbuild process; only the running Codex task process matched the clone path in its command text.
- The resumed PR12 live root `%TEMP%\weaver-styling-resume-pr12` was removed after `weaver down`; host PID 7728, widget PID 48016, and watcher PID 44008 were all absent.
- The three-defect live verifier stopped run-owned widget PID 51452 and watcher PID 46400 and removed the transient `.weaver-dev-port`. Its isolated ReleaseFast binary, log, and PID-targeted capture remain under `E:\tmp\weaver-three-defects-final` as evidence. The pre-existing user host/widget/watcher processes were not touched.

## Next executable task

Review the two green draft stacks bottom-up, starting with Native N1 / Weaver
PR01; no implementation or verification task remains.

## Path-icon centering follow-up (2026-07-23)

- Root cause: the Native stack child frame is geometrically centered at
  `runtime/native-sdk/src/primitives/canvas/widget_layout.zig:1704-1744`.
  A same-frame pixel scan disproved the inferred 6-8px layout-box offset. The
  remaining Noro bias came from `examples/noro-shell/widget.tsx:44,51-52,58`:
  the exact Rainmeter geometry is centered at `(14,14)` in a 28px meter, but
  the omitted raw-icon viewBox selected the contract default `0 0 24 24`,
  centered at `(12,12)`. PR13 now declares `viewBox="0 0 28 28"` without
  changing any path command or commit `4241b12` corner radius.
- Assumption/evidence rule: button centers are the checked-in
  `Variables.inc` geometry `(64,290)`, `(170,290)`, `(276,290)` in the
  340x356 widget capture. Bright icon pixels are those with RGB channels each
  at least 160; this excludes the dark button chrome and includes antialiased
  icon coverage consistently before and after.
- Before (`E:\tmp\weaver-icon-centering-before-window.png`): prev
  `(65.5,291.5)`, pause `(171.5,292.0)`, next `(277.5,291.5)`, respectively
  `(+1.5,+1.5)`, `(+1.5,+2.0)`, `(+1.5,+1.5)` from the authored button
  centers. After: all three are `(-0.5,-0.5)`.
- Native N5 adds a reference-renderer regression at
  `src/primitives/canvas/widget_builtin_tests.zig:808`: a 100x100 centered
  pressable panel with a 28px path icon scans the rendered alpha bbox and
  asserts both center axes are within 1px. N5 `3a16880f` passes focused canvas
  (36.4s), stock (94.3s), and widget-profile (58.7s); N6 `bdac8c22`
  stock/profile pass (89.6/66.4s), N7 `63554853` (94.3/66.4s), and N8
  `111bb748` (80.5/87.4s).
- Final Weaver exact-head gates all pass: PR08 `2908b6b5` (45 Node tests,
  typecheck, runtime Zig, release audit), PR09 `f1fb2de5`, PR10 `56173ca5`,
  PR11 `b4da16a6`, PR12 `2ebbe42e`, and PR13 `3740b951` pass the same four
  gates; PR13 additionally passes `weaver check examples/noro-shell`.
  `audit:release` passes all 13 Weaver heads at exact pins
  `0e16af24/d6389750/d903766c/d903766c/aa6eacd5/eb6416df/eb6416df/3a16880f/bdac8c22/63554853/111bb748/111bb748/111bb748`.
- Mandatory minimized-desktop visual gate:
  `E:\tmp\weaver-icon-centering-final-visual-gate.png`, reopened with the
  image viewer at original resolution. Numeric scan PASS: prev bbox
  `57,283..70,296`, center `(63.5,289.5)`; pause
  `163,282..176,297`, center `(169.5,289.5)`; next
  `269,283..282,296`, center `(275.5,289.5)`. Every axis is 0.5px from its
  authored button center. Solid geometry, exact paths, and all three corner
  shapes remain visually intact.
- GitHub rollups: pending the force-with-lease restack at the time this
  evidence commit was authored; final check URLs/results are recorded in the
  PR bodies and run report after polling.

## CI readiness hardening after centering restack (2026-07-24)

- Assumption/action: two independently reproduced Intel failures on PR08 and
  PR12 were treated as a real flaky gate rather than hidden by repeated
  reruns. Both read the macOS HTTPS fixture's port file after creation but
  before its contents were written. PR01 now publishes that fixture file by
  atomic replace, and its reader waits through an observed empty file. The
  earlier PR13 Apple failure likewise replaced a single `setImmediate`
  scheduling guess with an awaited server `connection` event while retaining
  the exact one-notification assertion and a 5s test timeout.
- Weaver PR01-PR13 were restacked from the hardened PR01 base. Exact code
  heads are `513608a8/1161ff90/7cea4e77/303d8c40/b79a0074/03ce828f/83b9892e/`
  `a08aebf5/d2a80577/884e65cf/4a967c8c/237ff406/9f9c9a1b`.
  Every exact head passes `npm test`, `npm run typecheck`,
  `zig build test -Dweb-layer=exclude -Dtrace=off --build-file runtime/build.zig`,
  and `npm run audit:release`; PR13 also passes
  `weaver check examples/noro-shell`.
- Native N5-N8 commits and Weaver gitlinks remain unchanged:
  `3a16880f/bdac8c22/63554853/111bb748`. No production assertion, test, or CI
  step was removed or weakened.

## Interaction-state shadow and descendant styling extension (2026-07-24)

- Native N8 `c61d3518` adds `inherit` / `none` / value shadow overrides to
  hover/pressed styles. State resolution uses the node itself when it claims
  press, otherwise the nearest press-claiming layout ancestor. Descendant
  invalidation walks run only when hover/pressed IDs change, so the state
  machinery adds no idle polling or timer.
- Native regressions cover pressed shadow precedence, explicit shadow removal,
  descendant foreground resolution, descendant state-shadow invalidation, and
  the full larger halo on both press and release. Focused widget-profile canvas
  PASS; full stock PASS in 25.5s; full widget profile PASS in 71.2s. Git's
  `usr\bin` was added to `PATH` for the repository's existing `test -f`
  assertions; both WebView2 DLLs were present before the corrected rerun.
- Weaver PR11 `2f416b9` compiles named, arbitrary, inset, color-composed, and
  `shadow-none` hover/pressed shadows, projects their wire properties, and
  rejects an orphan descendant variant with the
  `NearestPressableAncestor` fix-it. The contract and conjure skill document
  the implicit nearest-button/slider rule and require no `group` class.
- Assumption: `weaver check` requires the pressable ancestor to be statically
  provable in the same JSX tree. A reusable component that authors descendant
  state utilities must also contain its button/slider owner, or the stateful
  child must be inlined at the owner.
- Assumption: the two fixed Weaver interaction records may grow from 16 KiB
  to a ratcheted 26 KiB total at the 128-node limit (104 bytes each) to retain
  state shadow geometry. This is bounded Weaver-tree storage; Native keeps
  rare style commands in its existing side channel and does not grow the
  common `Widget` arena.
- Weaver exact-head gates PASS: PR11 Node 52/52 in 31.4s, typecheck, runtime
  Windows-flag Zig in 8.9s, release audit; PR12 Node 54/54 in 33.7s,
  typecheck 2.1s, runtime Zig 0.5s, release audit 0.4s; PR13 Node 54/54 in
  34.8s, typecheck 2.1s, runtime Zig 7.6s, release audit, and Noro check.
  Release audit PASSes all 13 heads at exact branch-local Native pins.
- Noro PR13 `012b3dc` preserves the exact custom icon paths, `0 0 28 28`
  view boxes, and `8.33px` / `37.5px` corner geometry. All three buttons now
  swap to fill `#141414`, inset shadow `0 2px 4px #0000004d`, and descendant
  icon color `#b6b6b6` while pressed.
- Pressed visual gate PASS. A real Win32 left-button hold targeted the no-op
  previous button so the icon path remained identical. Both captures were
  reopened at original resolution:
  `E:\tmp\weaver-pressed-state-20260724\noro-pressed-held.png` and
  `E:\tmp\weaver-pressed-state-20260724\noro-released.png`. During hold the
  fill is darker, the normal inset highlight is replaced by the dark inset,
  and the icon dims; release fully restores all three. Numeric means:
  fill `25.49` held vs `31.19` released; icon `164.91` held vs `187.10`
  released.
- Installed idle gate PASS. The updated Noro installation ran without a dev
  watcher or provider subscription. After more than two minutes settle, PID
  36800 advanced `0.000ms` TotalProcessorTime over `60.042s`.
- Assumption: Weaver's host uses machine-global lifecycle objects, so the
  existing clone-owned Noro installation was uninstalled to run the dev gate,
  then restored from the updated PR13 source for installed-mode idle
  verification. The unrelated source-missing Pomodoro registry entry was not
  modified.
- CI code-head runs: PR29 `30088527353`, PR30 `30088529927`, PR31
  `30088531190`. They were pending when this ledger entry was authored; final
  rollups are recorded in the PR bodies and compact run report so a
  documentation-only evidence commit does not recurse indefinitely.
