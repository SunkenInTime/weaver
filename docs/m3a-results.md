# M3a results: immediate canvas and the Windows render path

M3a adds the contract's immediate-mode `<canvas>` without turning the rest of
the widget tree into an animation loop. The proof is
[`examples/visualizer`](../examples/visualizer/widget.tsx): 28 synthetic
spectrum bars in a transparent 288 x 84 desktop-layer widget. The final
ReleaseFast build is shown in [m3a-visualizer.png](m3a-visualizer.png).

## What landed

The SDK exposes the exact `CanvasCtx` surface from CONTRACT.md. An `onFrame`
turn builds one flat `Float64Array`; opcodes carry geometry followed by a
packed RGBA integer. Colors are parsed and cached in JS. The QuickJS boundary
copies and validates a bounded batch, and Zig owns the decoded command/point
storage for each canvas node. Calling a retained context after `onFrame`
returns throws.

`fps` is capped at 60. An omitted value draws once per React render. Sub-60
canvases use the SDK effect timer with timestamp gating; max-rate canvases
chain the next JS turn from the completed surface frame, preventing an
independent producer from building a queue. `t` and `dt` are monotonic seconds
from the native frame/timer timestamp after the first native callback.

The Native SDK fork is on `weaver-fork-m3`:

- `71a50d2e` adds a small, upstreamable immediate-command seam to builder UI
  and lowers rects, rounded rects, circles, lines, and polylines into the
  existing keyed display list.
- `9611804b` enables the Windows retained pixel baseline, caches one layered
  DIB and memory DC per surface size, copies only changed rows, converts and
  premultiplies only the physical dirty rectangle, and invalidates only that
  rectangle on non-layered windows.

The fork change is 215 insertions and 48 deletions across six files. The
parent runtime/SDK/CLI implementation is 513 insertions and 13 deletions
across ten existing files, plus the visualizer example and this report.
No D3D11 presenter or SIMD path was added: damage-aware rasterization and
removing per-frame GDI allocation produced the certain win first.

## ReleaseFast measurements

Measurements used the same round-5 method: visible transparent desktop
window, actual frame count at the surface callback, `TotalProcessorTime`
delta over 15 seconds expressed as percent of one logical core, and
`Win32_PerfFormattedData_PerfProc_Process.WorkingSetPrivate`. Runtime tracing
was disabled; the diagnostic counters emit only every 300 events. The binary
was 6,619,648 bytes (6.31 MiB), with nine threads.

| Profile | Requested | Achieved presents | Changed JS frames | CPU, one core | Private WS |
|---|---:|---:|---:|---:|---:|
| 288 x 84 | 30 fps | 31.9 fps | about 29.3 fps | **5.00%** | 13.82 MiB |
| 288 x 84 | 60 fps | **58.2 fps** | same as presents | **8.95%** | 13.80 MiB |
| 480 x 320 | 30 fps | 32.0 fps | about 28.6 fps | **16.02%** | 15.30 MiB |
| 480 x 320 | 60 fps | **49.4 fps** | same as presents | **38.92%** | 15.23 MiB |

The sub-60 Native SDK timer still causes a surface scheduling pass on timer
wakeups that timestamp gating later rejects. Consequently the 30 fps cases
present at the Windows scheduler's roughly 31.9 Hz cadence while content
changes at roughly 29–30 Hz. This is real measured work, not removed from the
CPU number.

### Before/after

Round 5 used a 24-bar retained-tree visualizer and requested 62.5 updates/s.
It rebuilt and rasterized the full widget each time. M3a's proof has 28 bars
and uses one immediate batch, so the comparison is directional rather than a
microbenchmark of identical JS.

| Window class | Path | Requested / achieved | CPU, one core | Private WS |
|---|---|---:|---:|---:|
| 260 x 120 | Round-5 full-frame retained tree | 62.5 / 39.4 fps | 12.39% | 13.36 MiB |
| 288 x 84 | M3a immediate canvas | 60 / **58.2 fps** | **8.95%** | 13.80 MiB |
| 288 x 84 | M3a immediate canvas | 30 / 31.9 presents | **5.00%** | 13.82 MiB |
| 480 x 320 | Round-5 full-frame retained tree | 62.5 / 36.2 fps | 30.31% | 14.30 MiB |
| 480 x 320 | M3a immediate canvas | 60 / **49.4 fps** | **38.92%** | 15.23 MiB |
| 480 x 320 | M3a immediate canvas | 30 / 32.0 presents | **16.02%** | 15.30 MiB |

The small-widget hard targets are met at the boundary: 30 fps is 5.00% of one
core, and max-rate animation reaches 58.2 fps at 8.95%, below the 12% ceiling.
The requested 60 is not an exact lock because the software surface scheduler
occasionally misses a 16.7 ms slot.

The 480 x 320 result is still raster-bound. Dirty display-list diffing avoids
the unchanged card, but 28 changing bars have a union spanning most of the
canvas. The reference renderer must shade that large union on the CPU, and
`UpdateLayeredWindow` must submit the full cached bitmap even though only dirty
rows are copied and premultiplied. M3a makes 60-class animation viable for
widget-sized canvases; larger visualizers still demand tiled damage, a GPU
raster path, or the deferred D3D presenter. The old attribution that ULW was
roughly one percentage point remains consistent: the dominant scaling follows
dirty pixel area, not DIB allocation.

## Verification

- `npm run typecheck` and `npm test`: pass (7/7 Node tests). The reconciler
  test covers the canvas host node, 60 fps cap, typed command submission,
  packed colors, and context lifetime guard.
- `cd runtime && zig build test`: pass, including the bounded wire decoder
  test for packed colors and polyline points.
- `cd runtime && zig build -Doptimize=ReleaseFast -Dweb-layer=exclude
  -Dtrace=off`: pass; this compiles and links the touched Windows C++ host.
- The fork's `test-canvas`, `test-desktop-canvas-widget`, and
  `test-desktop-canvas-frame` run 1,098 tests: 1,087 pass, three skip, and
  eight fail. Every failure is an existing widget-profile capacity mismatch
  from fork HEAD `71df7a38` (tests assert stock command/path/glyph limits while
  the fork intentionally compiles smaller limits); none enters the new
  immediate-command or Windows presenter code.
- Clock and pomodoro retained-tree regressions render correctly in
  [m3a-clock.png](m3a-clock.png) and [m3a-pomodoro.png](m3a-pomodoro.png).
  A non-canvas widget has no registered canvas-frame callback, so no new
  render loop exists between its existing timer or input changes.
- All widget processes used for screenshots and measurements were stopped.

## Build and run

Use Zig 0.16.0 and install the workspace dependencies:

```powershell
$env:PATH = "E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0;$env:PATH"
npm install
npm run build
cd runtime
zig build -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off
cd ..
node cli/dist/index.js check examples/visualizer
node cli/dist/index.js bundle examples/visualizer
runtime/zig-out/bin/weaver-widget.exe examples/visualizer/dist
```

`runtime/native-sdk` points at the committed `weaver-fork-m3` submodule
revision; no SDK source is copied into Weaver.
