# Styling breadth results

Run date: 2026-07-21–22 on Windows 11. Both stacks remain unmerged draft-PR
stacks. Weaver is based on `master`; Native is based on `weaver-main`.

## Stack summary

| Layer | Weaver draft | Native draft |
|---|---|---|
| 01 / N1 | [#19 spacing and sizing](https://github.com/SunkenInTime/weaver/pull/19) | [#7 layout spacing](https://github.com/SunkenInTime/native/pull/7) |
| 02 / N2 | [#20 flex completeness](https://github.com/SunkenInTime/weaver/pull/20) | [#8 flex](https://github.com/SunkenInTime/native/pull/8) |
| 03 / N3 | [#21 radii and borders](https://github.com/SunkenInTime/weaver/pull/21) | [#9 radii and borders](https://github.com/SunkenInTime/native/pull/9) |
| 04 | [#22 Tailwind v4 palette](https://github.com/SunkenInTime/weaver/pull/22) | none |
| 05 / N4 | [#23 text pack](https://github.com/SunkenInTime/weaver/pull/23) | [#10 text](https://github.com/SunkenInTime/native/pull/10) |
| 06 / N5 | [#24 shadows](https://github.com/SunkenInTime/weaver/pull/24) | [#11 shadows and font seam](https://github.com/SunkenInTime/native/pull/11) |
| 07 | [#25 bundled fonts](https://github.com/SunkenInTime/weaver/pull/25) | rides N5 |
| 08 / N5 | [#26 path-based icons](https://github.com/SunkenInTime/weaver/pull/26) | [#11 retained path seam](https://github.com/SunkenInTime/native/pull/11) |
| 09 / N6 | [#27 stack and overflow](https://github.com/SunkenInTime/weaver/pull/27) | [#12 stack and overflow](https://github.com/SunkenInTime/native/pull/12) |
| 10 / N7 | [#28 image v2](https://github.com/SunkenInTime/weaver/pull/28) | [#13 image v2](https://github.com/SunkenInTime/native/pull/13) |
| 11 / N8 | [#29 interaction](https://github.com/SunkenInTime/weaver/pull/29) | [#14 interaction](https://github.com/SunkenInTime/native/pull/14) |
| 12 | [#30 retro player showcase](https://github.com/SunkenInTime/weaver/pull/30) | none |
| 13 | [#31 Noro shell fidelity showcase](https://github.com/SunkenInTime/weaver/pull/31) | rides repaired N7/N8 |

## Path-icon redesign

PR08 now resolves literal `<icon name>` values against all 1,749 names in
`lucide-static@1.26.0` and embeds only referenced geometry. Literal custom
`d` accepts the SVG grammar at bundle time; `svg-pathdata@7.2.0` expands it to
absolute M/L/C/Z, including Q-to-C and arc-to-C conversion, before Native sees
it. Unknown full-catalog names get a nearest-name fix-it, and normalized path
data has an independent 8 KiB per-node cap.

Native N5 retains decoded path elements in the existing rare-command side
channel, fits/centers a 24-unit view box into the icon box, and emits the
existing Path display-list command. Named icons use a two-unit round stroke;
custom icons fill unless `stroke` is positive. Both modes use the node's text
color. D3D still rejects Path and uses its existing per-command CPU fallback.
The font subset, codepoint map, reserved face id 64, and TTF asset are deleted,
so both custom-font slots are available.

The catalog pin is npm tarball SHA-1
`cdaec64ebb9ba10d9ce0fc065184b9dde3eb992d` with integrity
`sha512-6yCpa2ONICjlE19BuneIi75ASd9cCZhqJlzhAlQBi+99m2aZd2cNzxFVbDgPu7JLBZR2uDYO/EpLYtnhGw5Niw==`.
The Lucide/Feather license remains beside bundles that use named geometry.

Noro uses the exact solid shapes from upstream `Player.ini`: previous bar plus
triangle, play triangle, two pause rectangles, and next triangle plus bar.
The accepted capture
`E:\tmp\weaver-path-icons-20260723\noro-path-icons-visual-gate.png` was opened
at original resolution and compared with the opened authoritative preview
`E:\tmp\weaver-path-icons-20260723\noro-reference-preview.png`. PASS: solid
icons are centered and match the reference geometry; the 8.33/37.5 corner
radii, art, overlays, rim, pixel-font row, record dot, and subtle grille are
unchanged.

The accepted Styling Icons capture
`E:\tmp\weaver-path-icons-20260723\styling-icons-visual-gate-final2.png` was
opened at original resolution. PASS: full-catalog named icons, currentColor,
custom fill/stroke, and 16/24/32/40 sizes are crisp. An earlier capture was
rejected because an unrelated desktop widget overlapped its top-right anchor.

All Native N5-N8 stock and widget-profile suites pass. Weaver PR08-PR13 pass
npm test, typecheck, Windows-flag runtime tests, and release audit; the audit
sweep passes all 13 Weaver heads. Installed Noro advanced `0.000 ms`
TotalProcessorTime over `60.011 s` after a 129-second settle.

The first PR08 Apple-silicon session run caught a Clock provider stack
overflow. Returning icon-free TSX byte-for-byte was retained as a useful
no-op ratchet, but a second session failure proved it was not the cause. The
real defect was an inline 8 KiB `icon_path` array on every Weaver retained
node, inflating the 128-node tree by roughly 1 MiB and exhausting the smaller
macOS callback stack. PR08 now heap-owns that bounded string only for icon
nodes and frees it on replacement, removal, hot-swap failure/move, and
teardown. A node-size ratchet prevents the inline buffer from returning.
Windows Clock provider ticks plus a preserved-state hot swap pass with no
exception; PR09-PR13 were restacked again from this lowest fix.

Final path-icon heads before the CI ledger commit are Weaver PR08 `b26e362`,
PR09 `3e85fc6`, PR10 `c1ecb1c`, PR11 `8b76dfa`, PR12 `9c27d23`, and
PR13 `60c6976`; Native N5-N8 are `31d5710b`, `4981f66f`, `de432244`, and
`85f5dbe5`.

## Independent-review repairs

| Finding | Lowest layer | Final result |
|---:|---|---|
| 1 | Native N5 | Windows D3D decodes packet v7, parses the current header/command layout, renders per-corner solid rounded rectangles, and retains CPU fallback for unsupported command features. The build ratchet pins encoder, D3D, and AppKit versions together. |
| 2 | Weaver 06 | `attachEffects` copies existing rare-command metadata before appending box/text shadows and font ids. Exact tests cover text style plus text shadow and hover/pressed plus box shadow. |
| 3 | Native N1 / Weaver 01 | Width/height are optional preferred flex bases, min/max remain independent clamps, default shrink can compress, grow can expand, and authored zero is distinct from unset. |
| 4 | Weaver 02 | Cross-axis default is `stretch` through compiler, reconciler, retained tree, and Native projection; explicit `items-*` still wins. |
| 5 | Weaver 03 | Painted row/column lowering copies `flex_wrap` onto the inner layout node. |
| 6 | Weaver 03 | `weaver check` computes painted-lowered node/depth counts against Native limits 128/32 and emits `LoweredWidgetNodeLimit` or `LoweredWidgetDepthLimit` before runtime. |
| 7 | Weaver 01 and PR04 regression repair | `p-[Npx]` returns after compilation; its regression test passes at every final descendant. |
| 8 | Native N2 | Grow and shrink use bounded freeze-and-redistribute loops, including redistribution after max/min clamps. |
| 9 | Native N5 | Non-layout, hot-swap, hover, and pressed invalidation unions old/new `widgetShadowPaintBounds`, preventing stale halo pixels. |
| 10 | Native N6 | Stack percentages resolve from the parent content box; margins inset placement afterward. |
| 11 | Native N2 | Wrapped self-stretch measures intrinsic line cross size first and stretches only within that line's band. |
| 12 | Weaver 01 | Central numeric parsing rejects non-finite/absurd values; zero or invalid aspect ratios are check errors. |
| 13 | Weaver 01 contract | Contract states: utilities apply left to right; the last conflicting utility wins. |
| 14 | Weaver 05 | Named text sizes carry Tailwind paired defaults (`sm` 14/20, etc.); explicit `leading-*` overrides the pair. |
| 15 | Weaver 07 contract | Contract states that an exact file-stem match wins over family/weight resolution. |

The review rerun also fixed one deeper N8 defect exposed by the new composition
test: simultaneous hover and pressed metadata previously added two inferred
one-bit integers and overflowed in Debug. N8 now widens each presence bit to
`usize` before addition and has a direct two-style regression test.

## Acceptance anchor

`examples/retro-player-shell` is static and subscribes to no provider. It uses
the full stack in one retained tree: directional spacing and sizing, flex,
asymmetric radii, Tailwind colors, bundled font and tabular numerals, shadows,
Lucide icons, stack clipping, cover-fit local art, a generated tiled grille,
and native hover/pressed button channels. It has no interval, animated canvas,
media provider, fetch, or state loop.

The cover is the repository's Native deck `night-bloom.jpg`, reduced to
256×256 for the widget-profile decoded-image budget. `GeistPixel-Square.ttf`
and its OFL are reused from the repository's shipped font example. The grille
was produced with the built-in image generator as a seamless, flat two-color
perforated speaker grille; its generator metadata was removed and the fixed
1254×1254 canvas was normalized to a 256×256 nearest-neighbor tile. All three
assets remain local and portable.

## Windows A/B idle measurement

Same machine, release runtime and host, software renderer with pixels
presentation, isolated Weaver data roots, and one widget process at a time.
Each row is ten host `status.json` snapshots two seconds apart after startup;
CPU is Weaver host-reported process CPU percentage and memory is private MiB.
The parent was detached `origin/master` `a6d48af` with Native pin `78137351`.
The measured showcase was the accepted PR12 tree with Native pin `8aae6aa2`.
After CI exposed common-shape arena regressions, the final review head was
repinned first to compact Native `709989d2`, where the live acceptance smoke
was rerun, and finally to `80e74357`, which only inherits N3's Markdown arena
right-sizing. The original matched A/B samples below were not relabeled or
recomputed; the final aggregate Native and Weaver suites pass at `80e74357`.

| Widget | Sample uptime | CPU avg (min–max) | Private MiB avg (min–max) |
|---|---:|---:|---:|
| master `examples/now-playing` | 46–69s | 0.859% (0.700–0.993%) | 23.626 (23.478–23.673) |
| PR12 `examples/retro-player-shell` | 56–75s | 0.576% (0.500–0.700%) | 28.217 (27.975–28.310) |
| delta | — | -0.283 percentage points (-32.9%) | +4.591 MiB (+19.4%) |

This is the brief-required product A/B, not a causal microbenchmark: the two
widgets have different dimensions and retained content. It demonstrates that
the static showcase reaches idle without polling or crash-restart; it does not
attribute the memory delta to any one styling layer.

## Physical captures

Master baseline (`examples/now-playing`):

![Master baseline](./styling-breadth-baseline.png)

Final acceptance anchor (`examples/retro-player-shell`):

![Retro player styling showcase](./styling-breadth-showcase.png)

Both are physical Windows software/pixels native-window captures made with
Win32 `PrintWindow` and visually inspected. The computer-control plugin's
native pipe was unavailable on this host. macOS physical pixels remain
`UNVERIFIED (needs Mac)`; headless CI is compile/test evidence, not a physical
pixel claim.

Independent-review re-verification: PASS. The overlay row spans the cover and
places `03:18 / 05:42` at the far right. The earlier capture-only font claim
was insufficient: combined rare-command counts were inferred as `u1`, so the
headline's text-shadow + registered-font pair could wrap in ReleaseFast. The
final fix widens the count, and the exact Weaver projection now retains line
height 36, tracking 0.75, shadow blur 10, and font id 65. Native's deterministic
reference renderer draws `SECOND NATURE` at 30 px with the same bold/shadow
metadata and finds 10,625 differing pixels between GeistPixel-Square and the
built-in bold sans. The final live capture visibly has the square pixel glyphs.

The final live follow-up also visibly contains `night-bloom.jpg`; its log has
no image decode/register error. The WIC path now discards a failed one-shot
RGBA decoder graph and retries from a fresh on-load decoder through native
BGRA conversion, with a production decoder test using a real baseline JPEG at
the exact stock decoded-image budget. With the event-driven dev source watcher
alive, the static ReleaseFast widget's `TotalProcessorTime` advanced 15.625 ms
over 60,006.731 ms: one Windows scheduler/accounting quantum and no 100 ms
polling signature.

## Contract and verification

`sdk/CONTRACT.md` ends with consolidated element and class-family tables. The
imported `sdk/test/contract-tables.test.mjs` freezes the ordered row sets,
compiles a representative for every documented syntax branch, and proves
gradients, transitions, positioned layout, and unsupported state utilities
remain loud `UtilityError` failures. The complete command/evidence ledger,
assumptions, inherited Native fast-gate blocker, Mac-only unverified items,
and cleanup state live in `docs/styling-run-status.md`.

The final N4 repair stores non-default plain-text scale, weight, line height,
tracking, tabular-number, and max-line values as one rare retained metadata
record in the existing bounded command slice. The common `Widget` is exactly
728 bytes again (N3 size), default widgets allocate no record, and later
font/shadow/hover/pressed metadata composes in the same slice. Final Native
N4–N8 focused/stock/profile gates, every Weaver 05–12 npm/typecheck/runtime
gate, and the all-12-head release-audit sweep pass locally.

N3 retains four lossless f32 corner overrides and the unchanged hostile arena
bound. Its final repair pre-sizes capped Markdown block/list/table node buffers
from safe source-line upper bounds instead of eagerly reserving 64 full nodes
for short inputs; maximum capacities and truncation semantics do not change.

## Final CI rollup

The arena and independent-review repairs are confirmed by green Apple-silicon
headless CI on every final Weaver head PR19-30. All twelve PRs are green across
the Windows gate, Intel headless, Apple-silicon headless, and Apple-silicon
session jobs. PR28's first Intel attempt failed because the unchanged loopback
HTTPS setup read an empty temporary port file; a failed-job rerun on the same
`a0d567b` head passed the formerly failing step, the full Intel job, and the
dependent Apple-silicon session without a styling-code or test change. Native
PR7-14 have no configured GitHub checks; focused canvas plus stock and
widget-profile suites pass locally at every exact pushed head as recorded in
the run-status ledger. Physical macOS pixels remain `UNVERIFIED (needs Mac)`.

Three-defect follow-up CI: every restacked Weaver PR19-PR30 passed its Windows
gate, Intel headless, Apple-silicon headless, and Apple-silicon session jobs.
Native N5-N8 remain without configured GitHub checks and pass the full local
stock plus widget-profile suites; N5 also passes the exact reference-pixel
proof and N7 passes the production Windows baseline-JPEG boundary test.

## Noro shell fidelity follow-up

The fixed-height stack defect was a render-planner clip-composition error, not
a layout-origin error. An image emitter's equal-bounds square clip replaced
the rounded clip already pushed by the screen stack. Native N7 now combines
coincident radii per corner, so the child can tighten but never relax its
ancestor mask. An exact reference-renderer test places a real image inside a
padded fixed-height rounded stack and proves transparent padding and both
rounded top corners.

`examples/noro-shell` restores the cover, unmodified GridTile, and 20% GrainTile
inside the screen. Its grille opacity is 5%, tuned against the authoritative
Noro preview. The mandatory physical capture was opened at original resolution:
`E:\tmp\weaver-noro-pr13\noro-shell-visual-gate-final.png`. PASS: cover fills
without top/right bleed; the 14px shell rim is visible on every side; the row
reads `00:06 / LET IT GO / 03:58 AM` in the subsetted Cozette face; the record
dot remains inside the top-right; the grille is subtle; and all three Lucide
icons are centered.

The installed widget also exposed an obsolete Win32 top-level repeating
16ms frame timer. Removing that timer leaves explicit app timers, posted
one-shot frame requests, and the GPU-surface demand scheduler intact. After a
two-minute installed-mode settle, `TotalProcessorTime` advanced 0.000ms over
59.943s and 0.000ms over a consecutive 60.002s confirmation window.

Final CI is green for restacked Weaver PR28-PR31 across the Windows gate,
Intel headless, Apple-silicon headless, and Apple-silicon session jobs (runs
`29983968548`, `29983969846`, `29983972078`, and `29984071014`). Native
PR13/PR14 have no configured checks; their exact pushed heads pass full local
stock and widget-profile suites.
