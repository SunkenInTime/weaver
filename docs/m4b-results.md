# M4b results: hybrid retained texture layer

M4b makes a mixed retained-tree plus animated-canvas widget eligible for the
shared GPU renderer. The widget still rasterizes text and styled containers
with the Native SDK reference renderer, but it does so only when the retained
display layer changes. Canvas commands continue to cross the existing NSGP
pipe every animated frame.

Fork work is committed on `weaver-fork-hybrid` at `5e83a7d0`; the parent
repository pins that exact commit.

The static parity captures are [software](m4b-parity-sw.png) and
[GPU](m4b-parity-gpu.png). The three-process proof is
[m4b-three-mixed.png](m4b-three-mixed.png). These are real desktop captures;
the three proof processes were positioned side by side and other top-level
windows were temporarily hidden, then restored, for the capture.

## What landed

- The Native SDK display plan carries an explicit `retained` or `immediate`
  presentation layer from the builder canvas clip through render commands.
  A mixed surface now sends only immediate commands in its NSGP packet.
- The widget reference-rasterizes the retained layer into transparent RGBA.
  A retained-layer fingerprint suppresses rerasterization and upload while
  only canvas commands change. The reference-render memo is deliberately not
  reused here: its cached patches contain composited scene pixels, while this
  offscreen buffer must contain only the retained layer.
- The Windows client lazily creates a named shared-memory section, converts
  changed retained pixels from straight RGBA to premultiplied BGRA, and sends
  the section name, generation, and up to eight dirty rectangles in renderer
  protocol v2.
- `weaver-renderer` maps that section once per generation, updates dirty
  texture rectangles with `UpdateSubresource`, copies the retained texture to
  the swapchain back buffer, and then draws the ordered instanced canvas layer.
- Retained content is below all canvases in M4b. This matches the current
  Weaver examples, whose canvas nodes sit above card/title chrome. Arbitrary
  retained/canvas interleaving would require below/above retained textures and
  remains intentionally unimplemented.
- `fps={0}` now draws the initial canvas contents once, arms no timer or surface
  clock, and preserves the last frame when an active canvas transitions to
  zero. The audio visualizer keeps rendering through its decay and changes to
  zero when its provider bands and smoothed levels are both silent.
- The supervisor reports a deleted registered artifact as `source missing`,
  PID 0, with reason `registered source path does not exist`. It schedules no
  backoff or restart until the path exists again.

`examples/visualizer` is now a mixed retained card/title plus audio canvas.
`examples/now-playing` has a small canvas pulse next to its retained metadata.
The reproducible `examples/m4b-synthetic` and `examples/m4b-parity` profiles
provide the 480 x 320 performance and static parity cases.

The final gate-fix pass additionally caches the layer-filtered immediate
display list on the view, fingerprints retained source commands before render
planning, and gives each JS canvas one stable context plus one reusable 4096
value `Float64Array`. The bridge bulk-copies that typed range once and Zig is
the single finite-value validation boundary. These changes remove retained
tree planning, JS command-buffer garbage, and per-value QuickJS property reads
from the 60 Hz path.

## Visual parity and damage discipline

The parity profile uses fixed canvas commands and `fps={0}`. Both backends have
the same CPU-rasterized card, border, and text. Across the complete 560 x 390
desktop captures, 1.94% of pixels differ and the mean absolute channel error
is 0.71/255. The differences are confined to software-versus-SDF
antialiasing at the bar edges; retained pixels are visually identical.

The renderer log for a mixed static profile contains one connection, one
`retained-upload`, and no repeated frame entries over the subsequent 20-second
measurement. A 60 fps mixed synthetic profile likewise logged exactly one
retained upload while its renderer completed repeated 300-frame intervals.
That proves the retained title/card is neither rerasterized nor uploaded per
canvas frame.

## Performance

Windows 11, ReleaseFast, visible 480 x 320 desktop-layer windows. CPU is
`TotalProcessorTime` over 15 seconds as percent of one logical core. Private WS
is `Win32_PerfFormattedData_PerfProc_Process.WorkingSetPrivate`; private bytes
are `Get-Process.PrivateMemorySize64`. FPS is counted at the renderer after a
completed present.

### One mixed 480 x 320 synthetic widget at 60 fps

| Backend/process | Achieved FPS | CPU, one core | Private WS | Private bytes | Threads |
|---|---:|---:|---:|---:|---:|
| M4b shared renderer, final | 59.0-59.8 | 3.02% | 12.3 MiB | 52.7 MiB | 62 |
| M4b mixed widget, final | 59.0-59.8 | **12.92%** | **16.79 MiB** | 25.50 MiB | 13 |
| M4b mixed widget, before fix pass | 59.1-60.2 | 16.88% | 16.48 MiB | 25.11 MiB | 13 |
| M4b software control | about 60 requested | 38.85% | 25.35 MiB | - | 12 |
| M4a canvas-only widget | 60.18-60.19 | 9.38% | 12.33 MiB | 20.86 MiB | 5 |
| canvas-only regression, true changing 60 Hz | 60.0 | **13.33%** | 17.95 MiB | 26.72 MiB | 13 |

The hybrid path decisively avoids the full-frame software raster cost and cuts
private WS by about 8.6 MiB versus the software control. The frame-planning
split is fixed: immediate planning is p50 18 us / p90 21 us and contains no
text layouts, while the retained source is neither walked nor planned on an
unchanged frame. CPU falls by 3.96 points, but the <=10% target still misses by
2.92 points. The canvas-only true-changing control misses too, showing the
remaining bill is the JITless QuickJS `onFrame` command authoring plus the
main-loop/IPC turn, not mixed retained planning. The old M4a 9.38% control
changed its synthetic data at 30 Hz while presenting at 60 Hz; the final
control changes commands on every one of the 60 ticks and is the more honest
regression case.

### Three simultaneous mixed 480 x 320 widgets

| Process | Steady achieved FPS | CPU, one core | Private WS | Private bytes | Threads |
|---|---:|---:|---:|---:|---:|
| renderer | shared | **7.71%** | **14.50 MiB** | 57.72 MiB | 64 |
| mixed A | 58.3-59.3 | 11.98% | 19.06 MiB | 27.80 MiB | 11 |
| mixed B | 58.3-59.3 | 11.88% | 16.74 MiB | 25.45 MiB | 11 |
| mixed C | 57.9-59.3 | 12.92% | 16.73 MiB | 25.43 MiB | 11 |
| **total** | three visible widgets | **44.49%** | **67.03 MiB** | **136.40 MiB** | 97 |

Memory remains in the same class as M4a, the shared renderer stays below 10%,
and every widget holds roughly 58-59 fps. Each widget still misses <=10% by
1.88-2.92 points. This is a performance miss, not a measurement artifact:
all three windows were visible, their commands changed every frame, and every
counted frame completed through the renderer.

### Audio visualizer and paused clock

| Profile | Presents | CPU, one core | Private WS | Notes |
|---|---:|---:|---:|---|
| hosted mixed audio visualizer, before | 21.3 fps vs 30 requested | 9.06% | 17.34 MiB | provider timer contended |
| hosted mixed audio visualizer, final | **30.3 fps** | **10.94%** | **16.53 MiB** | continuous 440 Hz source; backend gpu |
| its shared renderer, final | same | 1.98% | 12.61 MiB | one upload at activation, none per frame |
| hosted visualizer after provider silence, before | no audio frames | 3.75-4.48% | 16.20 MiB | 30 Hz empty polling |
| hosted visualizer after provider silence, final | zero presents / zero pipe frames | **0.52%** | **15.41 MiB** | 1 Hz resume probe |
| mixed `fps={0}` widget | one initial present only | **0.104%** | 16.46 MiB | 15-second idle interval |
| renderer after that initial present | no further presents | **0.000%** | 13.18 MiB | one retained upload |

Provider delivery now marks JS state dirty but does not own a competing render
clock. While active, the 33 ms canvas timer drains queued provider frames and
commits provider state plus canvas commands as one generation. A continuous
generated 440 Hz WAV held 300 completed presents in 9.89-9.92 seconds. After
silence and decay, `fps={0}` cancels that clock; no pipe frame or present was
observed during the 15-second sample. The former residual was precisely the
main thread rebuilding on a 30 Hz empty provider poll (about 250 ms thread CPU
per 15 seconds even after reducing it to 4 Hz). The final 1 Hz resume probe
reduces this to 0.52%; an event-driven pipe-to-app wakeup is the clean future
way to remove the last half point without delaying sound resumption by up to a
second.

## Supervision and recovery

The source-missing test registered a temporary checked artifact, observed it
running, deleted the source directory, and sampled status at four and ten
seconds. Both samples reported:

```text
M4b Hybrid Parity  0  -  source missing  registered source path does not exist
```

There was no new PID and no backoff loop. The registration was then removed.

Live demotion is fixed and observed, not inferred. After killing the renderer,
status reported all three unchanged widget PIDs as `backend=software`.
[Two captures](m4b-demotion-software.png) [350 ms apart](m4b-demotion-software-next.png)
have different SHA-256 hashes and visibly different bar positions during the
gap. The renderer then restarted under backoff and the same three PIDs returned
to `backend=gpu`; no widget exited. The client detaches the dead DComp visual,
temporarily restores the layered-window binding with `SWP_FRAMECHANGED`, and
the runtime goes directly to a full pixel fallback rather than retrying an
invalid mixed packet. Promotion reverses the binding change and reuploads the
retained generation.

Win+D survival is also fixed. Desktop-layer windows are parented to the shell's
wallpaper WorkerW before first show and keep `HWND_BOTTOM` enforcement. Real
`Shell.Application.MinimizeAll()` captures show both the
[hybrid widget](m4b-wind-hybrid.png) and [canvas-only widget](m4b-wind-canvas.png)
visible and animated over wallpaper; `UndoMinimizeAll()` restores ordinary
apps without changing either widget backend.

## Verification

With Zig 0.16.0 at
`E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0` on `PATH`:

- root `npm run build`, `npm test` (7/7), and `npm run typecheck`: pass;
- runtime `zig build test` and ReleaseFast build: pass;
- renderer Debug and ReleaseFast builds: pass;
- host `zig build test` and ReleaseFast build: pass;
- Native SDK fork `zig build test-canvas`, including the new retained/immediate
  layer split test: pass;
- CLI check and bundle: visualizer, now-playing, parity, and synthetic profiles
  all pass and stamp `renderBackend: "gpu"`.

The fork's broad desktop-shell target remains at its pre-existing
widget-profile baseline: `test-desktop-ui-shell` passes 74/97 and its 23
failures are the expected one-window/view and reduced canvas-capacity cases.
The touched `test-canvas` target (including the new presentation-layer source
fingerprint test) and every production Windows/renderer/runtime compilation
path are green; M4b adds no new broad-suite failure.

## Verdict

M4b now lands the hybrid correctness, cadence, resilience, Win+D, damage, and
idle gates. Static retained pixels cross once per retained change; immediate
frames neither plan nor upload retained content; audio holds 30 Hz; renderer
loss visibly demotes and re-promotes live processes; and silence is 0.52% with
zero presents. The remaining failure is narrow but real: true-changing 60 Hz
JS command authoring costs 11.9-12.9% per widget rather than <=10%, and the
canvas-only true-60 control is 13.33% rather than M4a's 9.4% repeated-frame
baseline. The obvious next performance workstream is a native-mapped command
writer or compiled canvas callback path that removes QuickJS typed-index writes
and the JS-to-Zig turn from each scalar while keeping the CanvasCtx API intact.
