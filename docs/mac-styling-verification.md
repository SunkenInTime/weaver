# macOS physical verification plan — styling breadth stack

For the attended Mac session verifying the styling stack (Weaver PRs #19–#31 +
Native fork PRs #7–#14). Everything below compiled and passed headless CI on
Intel and Apple silicon, including the Apple-silicon session job — but
physical pixels and interactions have never been observed on real hardware.
This plan closes the `UNVERIFIED (needs Mac)` ledger in
`docs/styling-run-status.md`.

Written 2026-07-24 on the Windows side; the Windows captures referenced for
comparison live in the PR evidence and `docs/styling-breadth-results.md`.

## Setup

1. `git clone git@github.com:SunkenInTime/weaver.git && cd weaver`
2. `git checkout styling/13-noro-shell && git submodule update --init --recursive`
3. Build per README Quickstart (runtime `zig build -Doptimize=ReleaseFast`,
   host, `npm install && npm run build`). Zig 0.16.0, Node 22+.
4. Confirm virgin gates before judging pixels: `npm test`,
   `npm run typecheck`, runtime + host `zig build test`.

## Critical instrument note: verify WHICH path presented

The macOS packet path decodes wire v7 (three version bumps landed in this
stack: v5 shadows, v6 stack clips, v7 image tiling). A widget that silently
falls back to CPU-pixels presentation can look correct while the Metal packet
path goes untested. For every fixture below, check the widget log for the
presenter line (packet vs pixels) and record it next to the visual verdict.
A fallback where packet presentation was expected is itself a finding.

## 1. Pixel checks (one `weaver dev <example>` each; compare against Windows captures)

| Fixture | Closes | Look for |
|---|---|---|
| `examples/noro-shell` | N3, N5, N6, N7, 07, 08 | The everything-test. Asymmetric screen corners (36px top / 4px bottom) clip the cover art exactly; no bleed above/right; 14px shell rim all sides; inset button shadows; Cozette glyphs via CoreText match the Windows render; solid path icons centered in buttons (±1px — measure, don't eyeball); grille/grain tiles; per-corner 37.5px button arcs nest inside the 51px shell corner. |
| `examples/styling-spacing` | N1 | Margins, directional padding, percent widths, aspect boxes — geometry identical to Windows capture. |
| `examples/styling-shadows` | N5 | Outset + inset shadows, text shadows; NSShadow text pixels; hot-swap `shadow-lg` → none leaves no stale halo. |
| `examples/styling-icons` | 08 | Assorted Lucide names at several sizes, crisp AppKit path rendering, stroke caps/joins round. |
| `examples/styling-images` | N7 | cover/contain/tile, rounded image masks; tiling anchored top-left at native size. |
| `examples/retro-player-shell` | 12 | Composite regression; text pack: `tabular-nums` digits truly monospaced (CoreText `tnum` feature — line the clock digits up over a minute), `tracking-*` letter spacing visibly applied, `line-clamp` two-line ellipsis. |

## 2. Interaction checks (N8 / PR 11)

On `noro-shell` and `styling-interaction`:
- Hover a button: hover style applies natively, reverts on leave.
- Press and hold: pressed style while down, restores on release — including
  when combined with `shadow-inner` (the metadata-clobbering regression
  class).
- **Right-click AND control-click**: both must deliver `onRightPress` —
  control-click delivery is explicitly unverified on hardware.
- Double-click: `onDoublePress` fires once (not two presses + a double).
- Slider drag + click-at-position: value tracks pointer; press event
  coordinates sane at both ends of the track.
- Whole-surface drag still repositions the widget; button presses win over
  drag.

## 3. Measurements

- Idle-zero: `weaver install examples/noro-shell`, settle 2 min, then 60s of
  process CPU time delta (Activity Monitor sample or
  `ps -o cputime` twice) — must be ~one scheduler quantum. Record the number.
- Per-widget memory vs the Windows numbers in
  `docs/styling-breadth-results.md` (Windows noro-shell: 17.7 MB private).
- `weaver status` cost table matches Activity Monitor within reason.

## 4. Recording results

Append a "macOS physical verification" section to
`docs/styling-breadth-results.md` on the branch: per-fixture PASS/FAIL, the
presenter path observed, capture paths, the idle number, hardware + macOS
version. Flip each closed `UNVERIFIED (needs Mac)` entry in
`docs/styling-run-status.md` to `VERIFIED (Mac, date)` or file the failure.

## Out of scope here (pre-existing attended-Mac backlog, separate session)

External displays, Spaces/Stage Manager/fullscreen/lock, sleep/wake, physical
audio consent and route loss, drag-reposition feel at length, physical Intel
hardware, notarized packaging. These predate the styling stack and stay on
their own list (`docs/macos-port-brief.md` verification sections).
