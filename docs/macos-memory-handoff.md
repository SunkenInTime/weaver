# Handoff — Weaver widget memory reduction (Noro focus)

Continuation brief for a fresh agent. The prior thread ran in T3 Code (codex
harness) on Dara's other laptop, session id
`019fafbc-4c73-7ef3-a1e6-cd3ffd497f8f`, 2026-07-29. This doc is the recovered
state of that thread plus everything needed to continue. It lives on branch
`feat/macos-memory-work`, which is the complete working set: this doc, the
audit briefs, the `myclock/` bakeoff fixture, and the pinned native-sdk
memory work.

## Goal

Get a Weaver widget's Activity Monitor "Memory" number (phys_footprint) as low
as possible. Dara's target: **~20 MB per widget** (numbers in the 20s in
Activity Monitor). Current reality: Noro sits at ~155-166 MB, and even the
trivial Myclock widget is ~130 MB. Dara considers 100+ MB per desk widget
insane, and it is. Push back on the 20 MB target only with measurements, not
vibes — see "The remaining wall" below for why the honest near-term floor may
be higher, and what would have to change to actually reach the 20s.

Verify end-to-end: live process measurements (footprint, vmmap) AND visual
correctness of the rendered widget. A lower number with broken rendering is a
failure.

## Setup (2026-07-30)

You are already on the right branch if you can read this file. It is
rebased onto master with PRs #43-45 merged (error-propagation seams,
Noro art-shadow scrim, visualizer spectrum meter), so all current
widgets are available as test subjects.

- Native SDK memory work: branch `macos-memory-shared-renderer-prep`
  (commit `600d6cf6`, on top of `45336f24`) in SunkenInTime/native — the
  autorelease pools, framebufferOnly, analytic rounded clips, and the
  (unverified) Metal tiled-image primitive. Setup:
  `git submodule update --init`, then in `runtime/native-sdk`:
  `git fetch origin && git checkout macos-memory-shared-renderer-prep`.
- `myclock/` at the repo root is the clean isolated-benchmark fixture
  (`myclock/dist` is the bundle the bakeoff harness takes). Ignore any
  stale `.weaver-dev-port` in it.
- The audit briefs (`docs/receipt-sweep-brief.md`,
  `docs/error-propagation-brief.md`) are separate passes; do not mix
  them into this work.

Everything that was once loose on the old machine (the Noro scrim, the
briefs, the fixture) is now merged or on this branch; nothing else needs
recovering.

## What was diagnosed (in order)

Starting point: Noro at ~161 MB phys_footprint, of which ~105 MB graphics
(~87 MB "owned unmapped graphics" + ~18 MB IOAccelerator). Widget files are
220 KB; the album art (256x256) and ArtShadow.png (174 bytes) were ruled out.
Not a leak: 30-second sampling flat, near-zero CPU. It is high steady state.

Ruled out: the old "Dock-icon snapshot for accessory processes" postmortem
(~70 MB class) — current runtime passes no_activate, guards present. That old
28.5 MB validated baseline is stale for today's renderer/OS.

Found, fixed, verified:

1. **Missing Objective-C autorelease pools** around the Zig->AppKit packet
   presentation ABI (pixel, JSON-packet, binary-packet) and the parallel
   raster fill workers. Temporary NSMutableData / NSBitmapGraphicsContext per
   raster fill were never released. Fix verified live on Noro:
   raster backing 16.4 MB -> 23 KB, stale bitmap contexts 102 -> 0,
   heap 33.1 MB -> 19.2 MB, counts flat afterward.
2. **`CAMetalLayer.framebufferOnly = NO`** (inherited from old commit
   `b4711106`, not a current requirement). Changed to YES in production, NO
   kept for automation builds (automation does a 1x1 blit from the drawable
   for first-pixel verification). Semantically correct but **measured no
   footprint win** (Myclock 131.9 -> 132.0 MB). Keep the change, claim
   nothing for it.
3. **Per-command raster cache blowup from rounded ancestor clips.** Noro's
   command cache held 99 textures / 12.93 MB: 31 rounded fills (2.53 MB) +
   31 rounded strokes (2.53 MB) + 28 shadows (2.45 MB) + 6 images (5.37 MB)
   + 3 text. Rounded fills/strokes fell off the analytic Metal path solely
   because an ancestor clip had rounded corners (the progress strip generated
   most of them). Fix: analytic path extended — rounded fills honor rounded
   ancestor clips, analytic rounded strokes added, shader multiplies shape
   coverage by clip coverage. Verified live: cache 99 -> 37 entries, payload
   12.93 -> 7.87 MB, IOAccelerator resident 20.5 -> 14.2 MB, regions 76 -> 63,
   owned-unmapped-graphics virtual 92 -> 52 MB.
4. **Tiled-image expansion** (~4 MB): tiny source tiles were expanded into
   destination-sized retained rasters. Fix implemented: direct Metal
   tiled-image primitive, one lazily created source texture per image ID,
   repeat samplers. Restricted to untransformed, uncropped, full-source tiles
   with no image-local radius; everything else stays on the raster path.
   Shader compiles, full ReleaseFast build passes. **This fix's live memory
   win and visual correctness were NEVER verified** — the thread died during
   visual inspection. This is where you pick up.

## Where the thread died

Repeated failed attempts to visually inspect the live Noro window via
Computer Use (Sky cannot address Noro by name — it's an unbundled accessory
process with no LaunchServices identity; full-screen captures kept getting
blocked by T3 Code's own window and Mission Control wouldn't hold open).
Meanwhile a stale/current PID mixup happened once already (measured the wrong
binary's cache: 99 entries "still there" was a pre-rebuild PID — always check
process start time vs. build finish time, and use weaver's status API to find
the ACTIVE Noro PID; there were two at one point).

Better inspection route than Computer Use, discovered late in the thread:
weaver has a production GPU screenshot hook that reads the composited Metal
texture directly. The env var is inherited by the CLI watcher but NOT by an
already-running host — the instrumented instance must be launched fresh (or
use the window-capture approach in the weaver memory note
"verify-widgets-by-window-capture" if working with the Claude harness).

## Remaining work, in order

1. Rebuild, restart Noro on the new binary (verify PID start time > build
   time), confirm the tiled-image win: expect cache payload to drop ~4 MB
   more and entries 37 -> ~31, IOAccelerator to drop further.
2. Visually verify: outer 51px rounded clip, tile seams/orientation/opacity,
   progress-strip bottom corners, button borders / asymmetric corner radii.
   Re-run `test-canvas` (841 tests) after the tile patch.
3. Shadows: 28 entries / 2.45 MB still rasterized. Analytic shadow parity is
   harder; measure before attempting.
4. **The remaining wall:** see "The shared-renderer experiment" below. This
   is the real fight for the 20 MB target and has its own phased plan.
5. Keep the per-widget heap wins honest: re-sample after each change,
   multiple samples (footprint numbers were noisy run to run, ±10 MB).

## The shared-renderer experiment (the ~90 MB wall)

### Background

~89-91 MB "owned unmapped graphics" per process exists for EVERY widget,
tiny or complex, Metal composite or software pixels — because both paths
present through the same CAMetalLayer. Isolated bakeoff: Myclock 131.9 MB
(metal) vs 128.6 MB (software), only 3.4 MB apart. This baseline is
Metal/IOAccelerator driver + framework memory, not widget content. Without
solving it, the per-widget floor is ~130 MB.

**Key discovery: weaver's Windows runtime already solved this.** Widget
processes on Windows are device-less — display-list packets go over a pipe
to a shared renderer owned by weaverd, and the rendered surface is imported
into the widget's window by DirectComposition. See
`runtime/native-sdk/src/platform/windows/shared_renderer_client.h` and
`d3d_presenter.h` ("the widget never creates or loads a D3D device";
lazy connect, reconnect after renderer crash). That is why Windows widgets
sit at 20-40 MB. macOS is the outlier: every widget owns a CAMetalLayer and
pays the full Metal entry fee. The plan is to port the shared-renderer
contract to macOS: pipe -> unix socket/XPC, DirectComposition shared
surface -> IOSurface into the widget window's CALayer, d3d_presenter -> a
Metal presenter owned by the render host.

### The decision is made — gates are falsification checks, not a debate

Dara has approved the shared-renderer architecture (2026-07-29). Do not
re-litigate whether to build it; build it. The gates below exist to
FALSIFY the decision, and only these findings overturn it:

1. The probe delta shows the ~90 MB is not device-scoped (Phase 0 gate).
2. Per-widget overhead of the new design comes in an order of magnitude
   worse than expected — ~20 MB+ per widget over the current design's
   content cost, not a couple MB of IPC/surface overhead.
3. The design scales badly: per-widget marginal cost in the host grows
   super-linearly with widget count, or memory drifts upward over time
   (a leak-shaped curve) rather than holding a flat steady state.

Any of those three is a stop-and-report finding. Anything smaller is a
note in the results, not a reason to deviate.

### End state (this is what done means)

Every weaver widget on macOS shows in the 20s-30s MB in Activity Monitor
(phys_footprint), with one shared render host paying the Metal baseline
once. Rendering is visually identical to today (rounded clips, tiles,
strokes, shadows verified by screenshot), test-canvas and the runtime suite
pass, and every claimed number is recorded in this doc with multiple
samples. Work the problem however long it takes — but done is defined by
those recorded numbers, not by code existing.

Phases below are the strategy, in order. Each phase's numbers get recorded
in this doc BEFORE its conclusions are acted on — the numbers are what make
the next step trustworthy, including to you.

**Non-goals (read twice — these bound the tenacity):**
- Do NOT implement both architectures. The comparison happens in Phase 0
  with throwaway probes; after the gate, exactly one architecture is built.
- A failed gate is a FINDING, not an obstacle. If the gate number says the
  hypothesis is dead, the problem you are grinding on changes from "build
  the shared renderer" to "explain where the memory actually lives and
  report." Do not make a dead architecture work through sheer persistence.
- Do NOT weaken visual correctness or tests to hit the memory number. A
  low number with broken rendering is a failed end state.
- The deeper consolidation — host owns the windows, widget processes
  become pure JS runners with no AppKit — is OUT OF SCOPE for this pass,
  even if probe 3 makes it look attractive. Measure it (probe 3 stays),
  record the numbers as evidence for a future decision, but Phase 2 builds
  the device-less-widget-process design and stops there. Dara has
  explicitly deferred this call.

### Phase 0 — floor probes (throwaway code, no weaver changes)

Three standalone probe apps (~100 lines each), each measured with
`footprint` (multiple samples, note the spread):

1. Process + NSWindow + CAMetalLayer + Metal device, drawing one quad.
   = floor of the CURRENT architecture.
2. Process + NSWindow + plain CALayer with IOSurface contents, no Metal
   device anywhere in-process. = floor of a device-less widget process.
3. Process, no AppKit at all, allocate + fill an IOSurface.
   = floor of a pure JS-runner widget (host owns the window).

Record all three numbers here.

**GATE:** the bet rests on (probe 1 - probe 2) being large (expected
~70-90 MB). If it is small, the ~90 MB is not device-scoped, the shared
renderer will not reclaim it, and the plan must stop here and be rethought
— record the numbers and end the phase either way.

### Phase 1 — one-widget spike (ugly, hardcoded, throwaway)

Route ONE widget (myclock/dist, the clean fixture) through a minimal Metal
presenter running in a second process, frames delivered via IOSurface into
the widget window's CALayer. Ignore crash-reconnect, multi-client, and
protocol cleanliness. Deliverable: the widget process's footprint with real
weaver content (QuickJS + packet ABI) and a screenshot proving it renders.
Record the number here.

**GATE:** widget process should land in the 20s-30s. If it doesn't, vmmap
it, name what is still resident, and record that before any Phase 2 work.

**Scaling check (falsification condition 3):** extend the spike to N
clients — run 1, 2, 4, 8 myclock instances through the one host and record
host footprint at each N plus one widget-process footprint. Expected: host
grows linearly with a modest per-widget slope (surfaces + retained state,
single-digit MB per widget); widget processes stay flat. Then hold the
8-widget configuration for 30+ minutes and sample: steady state must be
flat, not drifting. Super-linear host growth or upward drift is a
stop-and-report finding per the falsification list above.

### Phase 2 — build the winning implementation as reviewed slices

Only if Phase 1's gate confirms an obviously winning design (if it does
not, stop at the finding and report — no build-out for a coin flip).

This phase IS the real, ship-bound implementation, and it is built as a
sequence of PRs against master — one coherent slice per PR. The reason for
slicing: the code review bots review one focused slice of production code
far better than a monolithic port. The throwaway probe/spike code from
Phases 0-1 never appears in a PR.

Spec: mirror the Windows contract
(`runtime/native-sdk/src/platform/windows/shared_renderer_client.h` is the
interface to follow; keep the lazy connect + reconnect-after-crash
semantics). A plausible slice sequence — adjust to what the spike taught:

1. IOSurface presentation path (widget window presents from an IOSurface).
2. Render host process + socket protocol (host side of the contract).
3. Device-less widget client (widget side; no Metal device in-process).
4. Cutover + per-client frame budgets — one host serving N widgets means a
   pathological widget can starve its neighbors; that is a new tripwire
   surface and it must name the budget when it fires (see CLAUDE.md).

For each PR:
- The description carries the receipts: relevant probe/spike numbers,
  before/after footprint where the slice moves it, and visual-verification
  screenshots. Every number states its measurement.
- Babysit it until the code review bots are fully green and the review
  score is 5/5 BEFORE starting the next slice. Address findings properly —
  fix real issues, push back with evidence on false positives; never
  satisfy a bot by weakening tests, suppressing warnings, or shrinking the
  change's honesty.
- Re-run live memory measurements after any review-driven change to the
  render path, and update the PR's numbers if they move.

### Recorded results (append below as phases complete)

- Phase 0 (probes): (pending)
- Phase 1 (spike): (pending)
- Phase 2 (slices — one line per merged PR): (pending)

## Validation status at handoff

- Native platform tests: pass.
- `test-canvas`: 841/841 pass (before tile patch — rerun after).
- Direct runtime suite: 57 pass, 1 skip.
- Known false negative: `zig build test` wrapper misclassifies an intentional
  provider-timeout warning on stderr as failure; the direct test executable
  passes. Don't chase it.
- ReleaseFast build + codesign: pass.

## Commands

```sh
# build (from runtime/)
mise exec zig@0.16.0 -- zig build -Doptimize=ReleaseFast

# isolated bakeoff (myclock is the clean fixture; Noro can't run isolated —
# its media provider intentionally requires Weaverd)
python3 scripts/macos-renderer-bakeoff.py \
  --runtime runtime/zig-out/bin/weaver-widget \
  --candidate metal-composite \        # or: software
  --bundles myclock/dist \
  --count 1 --warmup-seconds 5 --sample-seconds 5 \
  --output .zig-cache/myclock-metal.json --stage-trace

# live measurement (get ACTIVE pid from weaver status --json first)
footprint --noCategories --swapped --format bytes -p <PID>
vmmap -summary <PID>
```

## Reference numbers (all measured 2026-07-29, old laptop, may drift)

| Metric | Before | After fixes 1-3 |
|---|---|---|
| Noro raster cache | 99 entries / 12.93 MB | 37 / 7.87 MB |
| Noro IOAccelerator resident | 20.5 MB | 14.2 MB |
| Noro mutable raster backing | 16.4 MB | 23 KB |
| Noro heap | 33.1 MB | 19.2 MB |
| Noro phys_footprint | ~161-166 MB | ~166 MB (noisy; category shifts confirm wins) |
| Myclock phys_footprint (isolated) | — | 131.9 MB metal / 128.6 MB software |
| Per-process graphics baseline | — | ~89-91 MB (the wall) |
