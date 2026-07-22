# Styling breadth implementation plan

This is the implementation plan for items 1–9 of
[`docs/api-breadth-orders.md`](api-breadth-orders.md) — the styling-first slice
of roadmap item 5. It is written for the agent sessions doing the work. Read
`README.md`, `CONTEXT.md`, `sdk/CONTRACT.md` in full, ADRs 0001/0002/0003/0005/
0009, `docs/ROADMAP.md`, `docs/fork-consolidation.md`, and
`docs/api-breadth-orders.md` before changing code.

The slice is complete when an agent writing TSX can use every utility, element,
and event named in this plan on Windows and macOS, `weaver check` rejects
everything else with a fix-it, and the showcase widget (PR 12) visually
demonstrates the whole surface. Media providers (items 10–12 of the orders
doc), gradients, transforms, animations, and blur (the "alive pack") are
explicitly OUT of scope — do not pull them forward.

## Why this is mostly exposure, not construction

Reconnaissance (2026-07-21) established that the Native SDK fork already
implements most target capability at the drawing/layout layer; Weaver's class
pipeline simply never exposes it. Key facts, verified at these locations:

- Prop pipeline: `compileClass()` (`sdk/src/class-compiler.ts`) →
  `applyProps()`/`native.setProp` (`sdk/src/reconciler.ts:418-428`) → QuickJS
  callback (`runtime/src/bridge.zig:269-313`) → retained `tree.Node`
  (`runtime/src/tree.zig:37-77`, decode at 173–250) → `buildNode()` projection
  to Native SDK `ElementOptions` (`runtime/src/main.zig:415-505`). Props are
  direct in-process calls, not serialized opcodes. Colors cross as
  `#RRGGBBAA` strings.
- Layout is a hand-written shared Zig engine
  (`runtime/native-sdk/src/primitives/canvas/widget_layout.zig`), platform-
  neutral. `WidgetLayoutStyle` already has min/max size and `clip_content`
  (`widgets.zig:312-368`). Margins, aspect-ratio, flex-wrap, align-self do NOT
  exist and are real engine work in `layoutAxisChildren()` and friends.
- Drawing already supports four independent corner radii, strokes/borders,
  shadows, and rounded clip (`primitives/canvas/drawing.zig:101-163, 240-254`,
  `commands.zig:52-67`); panel chrome already emits shadow + fill + stroke
  (`widget_render_surfaces.zig:241-276`). `WidgetStyle` exposes only a scalar
  radius and unused border fields — the exposure gap is `WidgetStyle` +
  Weaver's projection, not the rasterizer.
- Retained content is CPU-rastered by the reference renderer on every path
  that matters (Windows software, Windows hybrid-GPU retained texture, macOS
  software; macOS Metal preserves per-corner radii natively). The D3D packet
  presenter's limitations (radius collapse, no strokes) affect only canvas
  packets and are NOT in scope to fix.
- Text: reference path is a custom TTF parser (no kerning/features,
  `font_ttf.zig:1-19`); macOS packet path is CoreText. The drawing layer
  already supports alignment, line height, wrap, and ellipsis
  (`text_layout_types.zig:23-63`); letter-spacing and tabular figures exist
  nowhere and are new work in both text paths.
- A runtime font registry accepting raw TTF bytes exists end-to-end
  (`runtime/canvas_fonts.zig:71-137`), including macOS CoreText registration.
  Weaver exposes none of it.
- `DrawImage` already supports source rect, arbitrary dest, `stretch`/
  `contain`/`cover`, opacity, and per-corner rounded mask
  (`drawing.zig:213-238`); the avatar widget (`widget_render.zig:1220-1250`)
  shows the intended rounded-image pattern. Tiling does not exist. Weaver sets
  only `image_id` and never passes fit or radius.
- Input: pointer coordinates, hover tracking, native double-click detection
  (`canvas_widget_events.zig:265-310`), `on_double_press`
  (`ui.zig:623-632`), right-click routing, and retained hovered/pressed state
  applied without JS (`widget_render.zig:2570-2584`) all exist natively.
  Weaver exposes only `onPress()`/`onChange()` with no payload.
- Stacking: paint order is child order; `Clip` supports per-corner radii but
  the render plan currently flattens rounded clips to rectangles
  (`drawing.zig:232-237` documents this) — preserving rounded clip through
  the plan is real work in PR 09.
- Hard limits in `runtime/src/tree.zig:4-11`: 128 nodes, 24 children, 192
  text bytes, 260 source bytes. You may raise a limit when a PR needs it;
  state the new value and its memory cost in that PR's description.

## Unattended-run autonomy contract

This run is unattended: no clarification round trips, no approval
checkpoints. Make the narrowest reasonable assumption consistent with this
plan, record it in the run status doc, and continue.

The agent is authorized to: create/commit/rebase/push the numbered `styling/*`
branches in both repositories; open and update draft stacked PRs; update the
Weaver submodule pointer to fork-stack commits; build, run, and kill Weaver
dev processes and example widgets on this Windows machine; install ordinary
project-scoped dev dependencies; create/remove temp test data under the repo
or temp roots.

Not authorized: merging to `master` or `weaver-main`, force-pushing shared
default branches, extending the frozen `weaver-fork*` branches, entering
credentials, installing system-level software, touching unrelated projects,
weakening a contract, deleting a test, or calling a stub complete to keep the
stack green. macOS cannot be exercised on this machine: macOS-specific code
must compile-gate cleanly and ride the existing macOS CI (`.github/workflows/
ci.yml` headless jobs); mark anything CI cannot prove as `UNVERIFIED (needs
Mac)` rather than claiming it.

Failure is a routing signal: retry with corrected inputs; take a safe
alternative; isolate a genuinely blocked gate as `BLOCKED` with evidence and
continue independent layers. After every coherent PR layer, commit and push.
Maintain `docs/styling-run-status.md` as the live handoff: current commits of
both stacks, stack map, completed gates, exact blockers, next executable
task.

## Delivery shape: two coordinated stacks

Identical mechanics to the macOS port (`docs/macos-port-brief.md:83-131`),
which is the precedent to imitate:

1. **Native SDK fork stack** in `SunkenInTime/native`, based on `weaver-main`.
   Branches `styling/N1-layout-spacing`, `styling/N2-flex`, … Owns layout
   engine, `WidgetStyle`, text, image, clip, and interaction-state work.
2. **Weaver stack** in this repository, based on `master`. Branches
   `styling/01-…` through `styling/12-…`. Owns compiler, reconciler, bridge,
   tree, projection, CLI validation, contract amendment, conjure skill,
   examples, tests, and submodule pins.

Each PR targets its parent, says `Stack: NN/12`, states what becomes usable at
that layer and what is deliberately missing, links the fork PR + exact
submodule pin when applicable, includes commands + results, and makes a
performance claim or explicitly declines to. Work in a fresh clone (e.g.
`E:\Projects\weaver-styling-run`), not in `E:\Projects\weaver` — the primary
tree is in active use.

Do not begin from an existing dirty state: `git clone` from GitHub, init the
submodule, verify `npm test`, `npm run typecheck`, and the Windows runtime
build pass on virgin `master` before the first branch.

## Design rules (binding)

- **Tailwind semantics exactly.** Every utility added must mean what it means
  in Tailwind (v4 names/values). Scale unit stays 1 = 4px. Arbitrary values
  in brackets where Tailwind allows them. When Tailwind offers a shorthand we
  don't support, the error must name the nearest supported form.
- **Unknown utilities stay loud.** Every addition moves from the reject list
  to the support table; everything else still throws `UtilityError` with a
  fix-it. Update `exampleUtilities` so `nearest()` suggestions stay good.
- **Fail at `weaver check`, never silently no-op.** If a utility parses but
  its renderer support didn't land (e.g. macOS gap discovered late), keep it
  a check-time error rather than shipping a no-op.
- **Idle-zero and honest billing hold.** Nothing here may introduce polling,
  per-frame work for static content, or hidden repaints. Hover/pressed swaps
  use the native invalidation path that already exists.
- **The contract is amended, not violated.** Append one section to
  `sdk/CONTRACT.md`: `# Styling breadth amendment (v0.4)` following the M2/M3
  amendment style ("Everything above stands", then the new surface). Each PR
  extends that section for what it ships; the class table and element table
  must be complete and exact when the stack closes.
- **Projection losses get fixed, not extended.** `light/normal→regular` and
  `semibold/bold→bold` weight collapsing (`runtime/src/main.zig:454-462`)
  should be resolved properly in PR 07 (font work); do not add new
  silently-lossy mappings anywhere.
- **Perf claims are A/B.** Any claim that a PR does not regress performance
  must be measured same-machine against the stack parent with an identical
  widget (established project policy). The reference-renderer hot path
  (per-node radii/border/shadow branches) is the place to be careful:
  branch on "feature absent" first so the plain-panel path stays unchanged.
- **Wire keys are fixed by this plan** (section below) so the SDK and Zig
  sides cannot drift. Do not rename them mid-stack; if one proves wrong, fix
  the lowest PR and restack.

## New wire surface (setProp keys)

All numbers are logical px unless noted. Absent key = unset. The compiler
emits only what the class string sets; `applyProps` defaulting mirrors the
existing pattern (`reconciler.ts:418-428`).

| Key | Type | Notes |
|---|---|---|
| `paddingTop/Right/Bottom/Left` | number | `p-*` keeps writing `padding`; directional utilities write sides; sides override uniform |
| `marginTop/Right/Bottom/Left` | number | new layout-engine capability |
| `minWidth/minHeight/maxWidth/maxHeight` | number | plumb to existing native min/max |
| `widthPercent/heightPercent` | number 0–100 | `w-full`=100, `w-1/2`=50; mutually exclusive with `width`/`height` (last write wins, matching Tailwind) |
| `aspectRatio` | number | width/height; applied when exactly one axis is determined |
| `alignSelf` | string | `start\|center\|end\|stretch` |
| `flexWrap` | bool | row/column line wrapping |
| `shrink` | number | 0 or 1 semantics only (`shrink-0`, `shrink`); default per Tailwind is 1 — implement as "may be compressed below preferred size to fit" and document precisely in the contract |
| `grow` | number | now accepts `grow-N` |
| `radiusTL/TR/BR/BL` | number | uniform `radius` stays; per-corner overrides it per corner |
| `borderWidth` | number | `border`=1 |
| `borderColor` | string | `#RRGGBBAA`; default when only `border` given: `#000000FF`? No — Tailwind's default border color is `currentColor`-ish gray; use `#E5E7EBFF` (gray-200) and say so in the contract |
| `shadow` | string | packed `"x y blur spread #RRGGBBAA"` preset-expanded SDK-side; empty = none |
| `shadowInset` | bool | inset box shadow |
| `textShadow` | string | same packed form, no spread |
| `textAlign` | string | `start\|center\|end` |
| `lineHeight` | number | multiplier (Tailwind `leading-*` semantics) |
| `letterSpacing` | number | px (can be negative) |
| `lineClamp` | number | max lines, ellipsis on last; `truncate` stays = clamp 1 without wrap |
| `tabularNums` | bool | fixed-width digits |
| `fontFamily` | string | registered family name; `sans`/`mono` reserved built-ins |
| `overflowHidden` | bool | clip children to node bounds incl. its radii |
| `fit` | string | image: `cover\|contain\|stretch` (default stretch = current behavior) |
| `tile` | bool | image: repeat at natural size from top-left |
| `hoverBackground/hoverTextColor/hoverOpacity/hoverBorderColor` | as base | state variants, resolved natively |
| `pressedBackground/pressedTextColor/pressedOpacity/pressedBorderColor` | as base | same |

Events: `fireEvent` (`runtime/src/bridge.zig:608-619`) currently passes
`(nodeId, kind, number|null)`. Extend the payload to carry `(x, y, w, h)` for
press events (logical px, node-local, plus the node's laid-out size so the SDK
can also hand widgets normalized 0–1 values). New handler kinds:
`"doublepress"`, `"rightpress"`. SDK surface:

```ts
interface PressEvent { x: number; y: number; u: number; v: number } // px + 0–1
<button onPress={(e?: PressEvent) => …} onDoublePress={…} onRightPress={…}>
```

`onPress` with the argument ignored stays source-compatible with every
existing widget.

## The stack

Weaver PRs (each with its compiler tests, zig tests where it touches
runtime/, contract-section update, and a minimal example under
`examples/` or an extension of an existing one):

- **01 `styling/01-spacing-sizing`** — directional padding + margins +
  min/max + `w-full`/`h-full`/fractions + `size-N` + `aspect-*`.
  Fork PR N1: margins, percent sizing, aspect-ratio in `widget_layout.zig`;
  expose max/min through `ElementOptions`.
- **02 `styling/02-flex-completeness`** — `justify-around/evenly`,
  `shrink`/`shrink-0`, `grow-N`, `self-*`, `flex-wrap`. Fork PR N2. Leave
  `items-baseline`'s end-alias as is, but note it in the contract as a known
  approximation (true baseline is out of scope).
- **03 `styling/03-radii-borders`** — per-corner radii + borders. Fork PR N3:
  `WidgetStyle` grows four radii; panel chrome emits stroke from Weaver
  style; projection wires both.
- **04 `styling/04-palette`** — full Tailwind v4 named palette + `white`/
  `black`/`transparent` for `bg-`, `text-`, `border-`, with `/NN` alpha.
  Compiler-only: one generated lookup table (a build-time script or a
  checked-in table with a test asserting spot values against known Tailwind
  hex). No fork PR.
- **05 `styling/05-text-pack`** — `text-left/center/right`, `text-[Npx]`
  (→ fontScale px/14), `leading-*`, `tracking-*`, `line-clamp-N`,
  `tabular-nums`. Fork PR N4: expose alignment/line-height (exists), add
  letter-spacing and tabular figures to BOTH text paths — reference path via
  per-cluster advance adjustment / max-digit-advance normalization, macOS
  via CoreText kern + `tnum` font features. `line-clamp` = wrap on + max
  lines + last-line ellipsis in `text_layout.zig`. This PR may raise the
  192-byte text limit if clamp makes longer text sensible.
- **06 `styling/06-shadows`** — `shadow-{sm,DEFAULT,md,lg,xl}` +
  `shadow-[…]` arbitrary + `shadow-inner` + color via `shadow-<palette>`;
  `text-shadow` presets. Fork PR N5 only if inset shadows or text shadow are
  missing at the drawing layer (verify; outset shadow exists).
- **07 `styling/07-fonts`** — bundled fonts: a `.ttf`/`.otf` file next to
  `widget.tsx` is discovered at bundle time, validated by `weaver check`
  (parseable, under a stated size cap), carried through `.weave` packs,
  registered with the native font registry at startup, selected with
  `font-[<file-stem>]`. Built-in `font-sans`/`font-mono` map to the
  registry's reserved built-ins. Fix the 5→3 weight collapse: register/select
  real weight variants where the registry supports them, and document the
  degradation rule for single-file custom fonts. TTF only if OTF/CFF is
  unsupported by the parser — then `weaver check` must say so.
- **08 `styling/08-icons`** — `<icon name="play" />`. Implementation: vendor
  the Lucide icon font (ISC license — include the license file) inside the
  SDK; the reconciler lowers `<icon>` to a text node with the icon font
  family and the glyph's codepoint; size via `text-*`/`w-*`, color via
  `text-<color>`. `weaver check` validates names against the vendored map
  with nearest-name fix-its. Ship a curated subset if the full font strains
  the font-slot size cap; state the subset rule. No fork PR expected (rides
  07's registry plumbing).
- **09 `styling/09-stack-overflow`** — `<stack>` element (children laid out
  at the stack's origin, each sized/aligned by its own utilities — overlay
  composition happens with `w-full h-full` + justify/items on children, no
  new per-child API) + `overflow-hidden`. Fork PR N6: stack layout mode;
  make rounded clips survive the render plan (the `drawing.zig:232-237`
  flattening) so clipped children — images, text, panels — actually clip to
  rounded bounds on the reference path and macOS.
- **10 `styling/10-image-v2`** — `fit` (cover/contain/stretch), class radii
  applied as the image's rounded mask (avatar-widget pattern), `tile`.
  Fork PR N7: tiling in `DrawImage` + reference renderer; projection passes
  fit/radius/tile from Weaver style.
- **11 `styling/11-interaction`** — `hover:`/`pressed:` variants (the four
  visual props each, resolved natively from the existing hovered/pressed
  state so a class-styled button finally reacts without JS), press-event
  coordinates, `onDoublePress`, `onRightPress`, and `<slider>` regains
  nothing (it exists) but gains a `pressed:` story consistent with buttons.
  Fork PR N8: state-variant style resolution in the surface renderer
  (`widget_render_surfaces.zig:241-245` is the exact override point);
  double/right press handler exposure.
- **12 `styling/12-showcase`** — `examples/retro-player-shell`: a
  static-data replica of the noro-player visual shell (rounded shell,
  screen area with a bundled placeholder image under rounded asymmetric
  corners, overlaid elapsed/title/clock text in a bundled retro font,
  tabular numerals, grille texture tile, three inset-shadow icon buttons
  with pressed states). No media provider — fake data. Plus: conjure skill
  updated to teach the full new surface, `docs/styling-breadth-results.md`
  with measurements and screenshots, and the consolidated contract table
  check. This example is the pre-gate for the noro port (orders item 13)
  and the acceptance anchor for review.

Fork PRs N1–N8 stack on `weaver-main` in the same order; if two are trivially
small, merging them into one coherent fork PR is acceptable — keep the Weaver
PR pins exact either way.

## Verification (every PR, mechanically checkable)

- `npm test` and `npm run typecheck` green (SDK/CLI).
- `zig build test` green in `runtime/` (Windows flags: `-Dweb-layer=exclude
  -Dtrace=off`).
- Native fork: `zig build test` stock AND `zig build test
  -Dwidget-profile=true` green.
- New utilities: compiler unit tests (accept table + reject/fix-it cases) in
  the existing test layout (`test/all.test.mjs` entry).
- Layout/text/draw changes: zig tests at the layer touched, following the
  fork's existing test conventions; for visual behavior, reference-renderer
  pixel assertions where the harness supports them.
- Each PR's example runs under `weaver dev` on this machine without errors
  (`weaver check` clean, process stays alive, no crash-restart in logs).
- The full existing CI matrix is the floor; macOS compile-gates via the
  headless CI jobs. Do not disable or weaken any CI step.
- Final: `docs/styling-breadth-results.md` includes the A/B idle-CPU and
  memory numbers for the showcase widget vs. `examples/now-playing` on
  master, and screenshots of the showcase.
