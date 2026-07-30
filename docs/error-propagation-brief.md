# Error-propagation pass — the seams

Brief for a detailed pass over every place an error can be born, swallowed, or
presented. The governing rule is the one this repo already committed to
(#39, "Name every silent failure where the developer looks"): a failure must
surface **where the developer is looking** — `weaver check` output, the dev CLI
stream, the per-widget log, or the widget window itself — and it must name the
budget/cause, not just exist as a bare error name.

Everything below was reproduced live on 2026-07-29 against noro-shell unless
marked speculative. The single worst end-to-end demo: add ~6 retained nodes to
`examples/noro-shell/widget.tsx` and the widget window renders a flat field of
**uninitialized GPU memory** (a different random color every launch), with
`weaver check` passing and zero error lines in any log.

## Seam 1 — the SDK render path has no error boundary (highest leverage)

- `sdk/src/reconciler.ts:835` `scheduleRender()` runs `renderRoot()` inside
  `void Promise.resolve().then(...)`. Any throw inside a re-render (including
  every budget error the Zig bridge deliberately throws) becomes an unhandled
  promise rejection.
- No `JS_SetHostPromiseRejectionTracker` is installed anywhere
  (`rg PromiseRejection runtime/` is empty), so QuickJS drops the rejection on
  the floor. Confirmed: over-budget fresh start logs *nothing*, hot swap logs
  only a bare `error: CallbackFailed`.
- `renderRoot()` (`sdk/src/reconciler.ts:403`) has `try/finally` around the
  batch but no catch: a throw mid-reconcile leaves a **half-built tree already
  committed** via `native.endBatch()`. There is no rollback and no "don't
  present a tree whose build threw."

Wanted: a render error boundary that (a) catches, (b) logs the message + stack
through a bridge call so it lands in the per-widget log, (c) puts the widget
into a visible error state (even a solid color + name is fine), and (d) never
commits a partially-built generation. Same treatment for effect callbacks,
`useInterval` callbacks, and `onFrame` canvas callbacks.

## Seam 2 — platform callback failures lose their name

- `runtime/native-sdk/src/platform/macos/root.zig:763` intends to log
  `platform callback failed: <name> (event <tag>)`, but what actually reaches
  the widget log is a bare `error: CallbackFailed` (observed three times
  today). Find where that line is emitted (likely the runtime's top-level exit
  path in `runtime/src/main.zig`) and make the *named* line the one that lands
  in the per-widget log before the process dies.
- After the runtime process dies, the host keeps the widget window alive
  showing whatever memory the surface had. That's both a UX bug and arguably an
  info leak (stale GPU memory). The host should clear the surface and/or show a
  tombstone when the runtime for a window is gone.

## Seam 3 — budget errors: born loud, dying silent

The bridge does the right thing at the throw site — `failFmt`
(`runtime/src/bridge.zig:142`) even documents that budget errors must name the
budget, the limit, and the ask. But:

- `runtime/src/bridge.zig:166` `createNode` → "node capacity exhausted" names
  neither `max_nodes` nor 128 nor the node count. Same for the generic
  "appendChild failed" / "insertBefore failed" (`bridge.zig:185,195`) which is
  how `max_children = 24` surfaces. Bring these up to the `failFmt` standard.
- All of them then die in Seam 1 anyway. Both halves need fixing.
- `runtime/src/tree.zig:4-21` budgets (`max_nodes 128`, `max_children 24`,
  `max_text_bytes 192`, `max_canvases 8`) are *statically checkable* for the
  initial tree — `weaver check` should count nodes/children of the authored
  JSX and fail with headroom numbers instead of letting the runtime discover
  it. (Separately: 128 is probably just too small — native SDK uses 1024/view
  and documents why it abandoned 128/256 — but that's a sizing decision, not
  this pass.)

## Seam 4 — image failures are log-only, screen-silent

- `runtime/src/main.zig:119` and `:1012` log `ImageTooLarge` etc. to the
  per-widget log, then render proceeds with a black hole where the image was.
  Nothing on screen, nothing in the dev CLI stream, `weaver check` passes.
- The 256 KiB decoded-RGBA cap
  (`runtime/native-sdk/src/runtime/canvas_limits.zig:118`, widget profile) is
  hit by *any* real album art; the bundled `cover.jpg` is 256×256 = exactly at
  the cap. `weaver check` can decode bundled assets and fail with the exact
  dimensions/byte math at check time. Host-fed `media.artPath` art needs either
  host-side downscale-to-fit or a runtime log + on-widget placeholder that says
  why.

## Seam 5 — dev loop failure modes

- `cli/src/index.ts:431-460`: rebuild failures print once via `printFailure`,
  but the runtime keeps hot-swapping/serving the **stale bundle** with no
  banner that what's on screen no longer matches the file. Persist an "out of
  date since <time>: <first error>" state in the dev stream (and ideally on the
  widget).
- The watcher (`cli/src/index.ts:458`) watches only `widget.tsx` — asset and
  font edits silently do nothing until an unrelated source change.
- Hot swap of a bundle that then throws mid-render: observed
  `dev hot swap applied (preserved root hook state)` immediately followed by
  process death (`CallbackFailed`) and an auto-restart that comes back blank.
  The hot-swap path already knows how to reject a bad candidate
  (`runtime/src/main.zig:362` evaluateCandidate) — extend that rejection to
  candidates whose *first render* throws, and keep the old bundle running.

## Seam 6 — canvas prerequisites are unchecked

- A `<canvas>` under a clipping ancestor (`overflow-hidden`) or behind an
  opacity layer never gets a host GPU surface; today the entire widget blanks
  with no diagnostic. The rule is already written down as a *comment* in
  `examples/visualizer/widget.tsx:3-5` — it should be a `weaver check` error
  (the ancestor chain is statically known) plus a runtime log if the surface
  is denied dynamically. Precedent: `CanvasNeedsExplicitSize`
  (`cli/src/index.ts:1373`) already does exactly this for percent sizing —
  same shape, new rule.

## Seam 7 — empty-catch inventory

Each of these should either handle-and-log, narrow to the specific expected
error, or grow a comment proving silence is correct (some already have one —
those are fine and are the model):

- `sdk/src/reconciler.ts:873, 910` — hot-swap seed parse/capture: silence is
  probably right, but a swap that falls back to fresh state should say so in
  the log (today "preserved root hook state" prints even when seeding failed).
- `sdk/src/class-compiler.ts:610, 642`
- `cli/src/host-tools.ts:195, 200, 206, 224`, `cli/src/origin.ts:5, 15`,
  `cli/src/index.ts:733, 812, 913, 1127`, `cli/src/weave.ts:344`
- Zig: 18 hits of `catch {}` in `runtime/src` (`rg 'catch \{\}' runtime/src`),
  plus `catch return null` / `catch return` sites in `geometry.zig:38,65`
  (corrupt geometry file → silently repositioned widget),
  `dev_reload.zig:61` (accept failure → dev reload just stops working),
  `js_engine.zig:100,110` (hot-swap capture failure → silent fresh state).
- `runtime/src/main.zig` msg-handler catches (lines 140-240) all log — good —
  but several then continue with stale state where a degrade should be marked
  once (e.g. repeated `provider dispatch failed` every 33 ms would flood; needs
  latch-and-summarize).

## Seam 8 — status surfaces that lie by omission

- `weaver dev` stream prints provider/present milestones but not their
  absence: a widget that never logs `presenter path=` never presented a frame —
  after N seconds that should be an explicit error line (it was the only
  signal, and today it's an *absence*).
- `~/Library/Application Support/Weaver/status.json.backend-*` orphan files
  accumulate silently; `weaver status` doesn't reconcile them.
- Uninstall/registry restore paths (`cli/src/index.ts:414, 486, 616, 694`)
  swallow the second-order failure by design (comments present) but nothing
  ever reports the widget/registry divergence at the *next* `weaver status`.

## Suggested acceptance test for the whole pass

One integration test per seam that used to be silent, each asserting a named
error is visible at the correct surface. The canonical one: a widget whose
tree exceeds `max_nodes` must (a) fail `weaver check` naming the budget and
count, and if forced through anyway (b) log
`node capacity exhausted: max_nodes=128, asked for 129` and (c) render an
error surface — never uninitialized memory, never a silent flat fill.
