# M3c results: Windows GPU renderer

M3c adds a hardware-only D3D11 packet renderer and a DirectComposition
flip-model presenter for animated canvas widgets. The 480 x 320 synthetic
proof is [m3c-visualizer-480.png](m3c-visualizer-480.png). Its rounded
corners and 86%-alpha card show the wallpaper through the DComp surface.

## What landed

The Native SDK fork is on `weaver-fork-gpu` at `45f3cb8e`. Windows now
registers the existing compact `NSGP` v4 binary packet presenter. A new
`d3d_presenter.cpp/h` unit owns:

- a hardware-only `D3D11CreateDevice` probe (never WARP), with
  `WEAVER_FORCE_SOFTWARE=1` as the deterministic fallback seam;
- a two-buffer `DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL` composition swapchain with
  stretch scaling and premultiplied alpha;
- an `IDCompositionDevice/Target/Visual` attached to a
  `WS_EX_NOREDIRECTIONBITMAP` top-level window;
- retained keyed command state for NSGP full and patch packets; and
- one instanced quad draw for solid rectangles, rounded rectangles, lines,
  and polyline segments, with SDF coverage and premultiplied blending.

`webview2_host.cpp` remains the lifecycle boundary. It keeps the child HWND
for input and frame pacing, makes that child visually transparent, preserves
`WS_EX_NOACTIVATE`/click-through/bottom-layer behavior, and destroys the GPU
presenter before the child. A refused hardware packet restores the existing
layered-window pixel path in the same frame.

The CLI stamps an internal `renderBackend: gpu|software` field into
`dist/widget.json` from the checked TSX tree. This means a retained-only
clock does not even initialize D3D, while a canvas widget requests hardware
and the host performs the real device probe. The Windows frame event reports
`d3d11` or `software`; weaverd exposes the corresponding `gpu|software`
value in both `weaver status` formats via a per-process backend report file.

## Performance

ReleaseFast, visible desktop-layer windows, real `Present(1, 0)` calls. CPU
is `TotalProcessorTime` over 15 seconds as percent of one logical core.
Private WS is `Win32_PerfFormattedData_PerfProc_Process.WorkingSetPrivate`.
Achieved FPS comes from the Native surface completion hook, reported every
300 presents. The large profiles used a temporary synthetic spectrum version
of the visualizer; the checked-in audio-backed 288 x 84 example was restored.

| Profile | Backend | Requested | Achieved | CPU, one core | Private WS | Private bytes |
|---|---|---:|---:|---:|---:|---:|
| 288 x 84 | M3a software | 30 | 31.9 presents / ~29.3 changed | 5.00% | 13.82 MiB | - |
| 288 x 84 | M3c GPU | 30 | 31.9 presents / ~29.8 changed | **3.23%** | 85.00 MiB | 132.82 MiB |
| 288 x 84 | M3a software | 60 | 58.2 | 8.95% | 13.80 MiB | - |
| 288 x 84 | M3c GPU | 60 | **58.8** | **6.98%** | 85.39 MiB | 134.13 MiB |
| 480 x 320 | M3a software | 60 | 49.4 | 38.92% | 15.23 MiB | - |
| 480 x 320 | M3c GPU | 60 | **~59.0** | **8.96%** | 85.24 MiB | 133.61 MiB |
| 800 x 400 | M3c GPU | 60 | **~59.0** | **6.35%** | 85.31 MiB | 134.18 MiB |

Both hard large-widget targets land. The 800 x 400 run being slightly cheaper
than 480 x 320 is normal sampling/driver variance: both submit the same 29
instances and the pixel shader covers much less work than one CPU core can
saturate. It should not be read as larger surfaces always costing less.

The honest bill is memory. This machine's D3D/graphics driver creates roughly
64-67 threads and takes the widget to about **85 MiB private WS / 133 MiB
private bytes**, around +71 MiB private WS over software. D3D device sharing
through weaverd or a multi-widget renderer process is now the obvious memory
workstream; per-process GPU widgets are CPU-efficient but not memory-small.

The static clock selected software without loading a D3D device: 12.95 MiB
private WS, 21.09 MiB private bytes, ten threads, and 0.21% of one core over a
15-second window containing its 1 Hz ticks. Its frame log has no free-running
surface cadence. Linking the GPU unit adds about 2 MiB private WS versus the
round-4 11 MiB static substrate, comfortably below the +8 MiB auto-selection
guardrail.

## Windowing and fallback verification

- The proof image shows per-pixel transparency under DComp; the top-level
  and child HWND background paints are suppressed so transparent swapchain
  pixels reveal wallpaper rather than a white class brush.
- Win+D left the GPU widget visible and non-iconic. A maximized Notepad window
  covered it, confirming the bottom-layer contract still holds.
- The existing `WM_WINDOWPOSCHANGING` bottom reassertion, no-activate style,
  and canvas input child remain in the path. A real Win32 mouse click on the
  pomodoro Start button changed persisted state from `running:false` to
  `running:true` and its remaining value advanced from 1818 to 1814.
- With `WEAVER_FORCE_SOFTWARE=1`, the same visualizer frame event reported
  `software`; the process used the unchanged M3a layered presenter.
- Live status reported `Visualizer ... gpu` and `Clock ... software`.

## Verification

- `npm run typecheck`: pass.
- `npm test`: pass, 7/7. The status table and artifact backend field are
  covered.
- `runtime: zig build test`: pass.
- `runtime: zig build -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off`:
  pass; this compiles and links the D3D/DXGI/DComp C++ unit.
- `host: zig build test` and ReleaseFast build: pass.
- Fork `test-desktop-platform` does not compile under the existing
  widget-profile limits (arrays compiled to one slot while stock tests index
  a second). `test-desktop-ui-shell` runs 97 tests, 74 pass and 23 fail for
  the same fork-wide one-window/one-view/128-widget capacity profile already
  documented in M3a. The production Windows build and the new Windows backend
  mapping test pass through the runtime test target.

## Honest limitations

This is not yet the full hybrid retained-text implementation from the target
architecture. The presenter accepts solid shape packets. Text, images,
gradients, curves, strokes, and effects refuse the packet and atomically
demote the whole surface to software. Consequently the M3 visualizer
(canvas-only) gets the GPU path, and retained-only widgets stay lean, but a
mixed text-plus-animated-canvas widget is software today. The next renderer
step is a cached CPU retained texture uploaded only on retained-tree damage,
then composed below the GPU instance layer. GPU glyph atlases remain out of
scope as planned.

No PDH GPU-engine column was attempted: the hard CPU/FPS targets landed, but
the memory result and hybrid retained layer are higher-value work than the
stretch metric.
