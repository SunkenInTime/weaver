# Receipt sweep — every limit gets a measurement or gets resized

Handoff brief for a one-pass audit of every numeric limit in weaver. Vocabulary
is from CLAUDE.md (receipt, tripwire, landmine): a limit without a measurement
is a landmine; a correctly sized limit is a tripwire — placed past where any
good widget goes, so only broken things touch it. The precedent for both the
sizing method and the receipt format is the Native SDK's
`runtime/native-sdk/src/runtime/canvas_limits.zig` comment block (measured the
worst realistic good view at ~500 nodes, set the cap at 1024, wrote the math
down) and weaver's own `runtime/src/tree.zig:11-18` canvas-budget comment
(the 336-rect meter receipt).

**Out of scope:** making limit violations visible (error boundaries, named
budget errors, check-time validation). That is `docs/error-propagation-brief.md`
and runs as its own pass, governed by CLAUDE.md's "DX is for humans and
agents" and "A limit developers can hit is a limit they must see". This sweep
only answers: is each number justified, and if not, what should it be?

## Deliverables

1. An inventory table (append it to this doc or a sibling results doc):
   constant, value, file:line, has receipt (Y/N), measured worst good case,
   verdict (keep / resize to N / delete).
2. For every no-receipt constant that survives: a receipt comment at the
   definition site, in the `tree.zig:11-18` style — what was measured, what it
   needed, what headroom the value leaves, and what the memory cost of the
   headroom is (usually ~zero: reserve big, commit lazily, pages touched only
   on use — but say so).
3. Resizes applied, with mirrors updated (see "Mirrored constants" below).
4. A short list of limits that should not exist at all (protocol invariants
   masquerading as budgets, or caps whose removal costs nothing).

## How to find the full set

The seed inventory below was produced with:

```
rg -n 'pub const max_|const max_|_cap|Limit|MAX_' runtime/src cli/src sdk/src
```

Re-run it — don't trust the seed to be complete. Also sweep `sdk/src` for any
soft limits (array slicing, string truncation) that don't announce themselves
as constants.

## Seed inventory — known suspects

### The starved tier (measure and resize first — these are the active pain)

- `runtime/src/tree.zig:4` `max_nodes = 128`. No receipt. Known too small:
  noro-shell + ~6 retained nodes kills the process
  (`docs/error-propagation-brief.md`, intro). The Native SDK documents why it
  abandoned 128/256 and sits at 1024/view
  (`canvas_limits.zig:17-28`). Measure noro-shell, visualizer, and the
  worst widget we'd call good; expect the answer to land near the Native SDK's
  1024 tier. Memory cost of the raise is address space, not resident pages —
  but verify the arena is not eagerly zeroed before claiming that
  (grep the tree-arena init for `zeroes`/memset; lazy commit dies if it is).
- `runtime/src/tree.zig:5` `max_children = 24`. No receipt. Surfaces as a bare
  "appendChild failed". A 25-item list is a normal widget, not pathology —
  this is almost certainly not a tripwire today.
- `runtime/src/tree.zig:6` `max_text_bytes = 192`. No receipt. 192 bytes is
  ~2 lines of text; measure real widgets' longest text node.
- `runtime/src/tree.zig:10` `max_canvases = 8`. No receipt, probably fine —
  but write the receipt saying why 8 clears any good widget.
- `runtime/src/tree.zig:7-9` `max_source_bytes = 260`,
  `max_icon_path_bytes = 8 KiB`, `max_font_family_bytes = 63`. Some of these
  are protocol/OS facts (260 smells like MAX_PATH, 63 like a null-terminated
  64-byte field) — if so, the receipt is "this is an OS/protocol bound, not a
  budget" and they should say that rather than look arbitrary.

### Already receipted (verify, don't rework)

- `runtime/src/tree.zig:19-21` canvas commands/points/wire values — receipt
  present (the 336-rect meter). Check the math still holds after any node
  resize.
- `runtime/native-sdk/src/runtime/canvas_limits.zig` — the model citizen.
  Read it before writing any receipt; match its format.

### Runtime, unreceipted

- `runtime/src/bridge.zig:27-28` `max_timers = 16`, `max_fetches = 4`.
  4 concurrent fetches for a widget that polls two APIs plus loads art may be
  tight; measure.
- `runtime/src/main.zig:73-74` `max_images = 16`, `max_image_load_attempts = 3`.
- `runtime/src/network.zig:10-11` request/response caps at 5 MiB each.
- `runtime/src/provider_protocol.zig:5-7` frame/ack queue capacity 4,
  command_line_capacity 256.
- `runtime/src/media_protocol.zig:3-5` text 512, source_app 256, art_path 259.
- `runtime/src/geometry.zig:18` `max_file_bytes = 512` for the geometry file.
- Also from the error-propagation brief: the 256 KiB decoded-image cap
  (`canvas_limits.zig:118`, widget profile) — hit by any real album art; the
  bundled cover.jpg sits exactly at it. This one has a receipt problem AND a
  sizing problem.
- QuickJS stack bounds (see commit `20b5a46`) — find where the bound is set
  and whether it has a receipt.

### CLI / packaging, unreceipted

- `cli/src/index.ts:85-86` `MAX_WIDGET_FONTS = 2`, font bytes 512 KiB.
- `cli/src/weave.ts:7-14` archive 64 MiB, file 16 MiB, entries 1024,
  name/author 256. Probably fine; write the one-line receipt ("a weave is a
  widget bundle; the largest real example is N") or shrink.
- Widget asset limit hit by the generated grille (commit `c67b4e3` "Fit
  generated grille within widget asset limit") — locate the constant, that
  commit is evidence a real asset already collided with it.

## Mirrored constants — resizes must move in lockstep

- `cli/src/index.ts:1006-1007` `nativeWidgetNodeLimit = 128`,
  `nativeWidgetDepthLimit = 32` are hand-copied mirrors of the runtime
  budgets so `weaver check` can fail early. Any resize of `tree.zig` budgets
  that skips these makes check lie. Preferred fix while you're there: emit or
  import the numbers from one source of truth so this class of drift can't
  recur; if that's not obvious to do, at minimum leave a comment on both sides
  pointing at each other.
- Depth limit 32: find the runtime-side counterpart and receipt both.
- Precedent for cross-boundary pinning done right:
  `canvas_limits.zig:46-57` documents that the AppKit host pins
  `NATIVE_SDK_PACKET_RETAINED_COMMAND_CAP` to the same value and what happens
  on mismatch. That's the bar.

## How to measure

- Real widgets are the ruler: `examples/noro-shell`, `examples/visualizer`,
  the native-sdk examples (notes, system-monitor, deck), and anything in
  recent history that hit a cap (the 336-rect meter, the 24-panel row, the
  grille asset).
- For tree budgets, count the lowered tree, not the JSX — `weaver check`'s
  `validateLoweredTreeBudgets` (`cli/src/index.ts:1011`) already computes
  lowered node count and depth; reuse it as the measuring tool.
- Sizing rule from precedent: cap ≈ 2× the worst realistic good case
  (Native SDK: measured ~500, set 1024).
- Before being generous, verify the lazy-commit claim per arena: fixed
  capacity is only free if construction is in-place and large fields stay
  uninitialized (`canvas_limits.zig:26-28`). An arena that memsets on init
  pays resident memory for the whole cap.

## Acceptance

- `rg -n 'pub const max_|const max_|MAX_' runtime/src cli/src sdk/src` returns
  zero constants that lack either a receipt comment or a "protocol/OS bound"
  comment at the definition site.
- `tree.zig` and `cli/src/index.ts` budget mirrors agree (ideally by
  construction).
- noro-shell with the +6-node repro from the error-propagation brief renders
  fine under the resized budgets.
- Nothing in this pass adds a new error path or check rule — if you find
  yourself doing that, you've drifted into the error-propagation brief's
  territory; note it there and move on.
