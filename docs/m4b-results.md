# M4b results: hybrid retained texture layer

M4b makes a mixed retained-tree plus animated-canvas widget eligible for the
shared GPU renderer. The widget still rasterizes text and styled containers
with the Native SDK reference renderer, but it does so only when the retained
display layer changes. Canvas commands continue to cross the existing NSGP
pipe every animated frame.

Fork work is committed on `weaver-fork-hybrid` at `5d066a3b`; the parent
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
| M4b shared renderer | 59.1-60.2 | 3.85% | 12.50 MiB | 54.49 MiB | 62 |
| M4b mixed widget | 59.1-60.2 | **16.88%** | **16.48 MiB** | 25.11 MiB | 13 |
| M4b software control | about 60 requested | 38.85% | 25.35 MiB | - | 12 |
| M4a canvas-only widget | 60.18-60.19 | 9.38% | 12.33 MiB | 20.86 MiB | 5 |

The hybrid path decisively avoids the full-frame software raster cost and cuts
private WS by about 8.9 MiB versus the software control. It misses the <=10%
per-widget target: the retained commands are not uploaded per frame, but the
current Native SDK frame planner still walks/plans the full mixed display list
before filtering the GPU packet. Splitting frame planning itself, rather than
only the presentation plan, is the next obvious CPU fix.

### Three simultaneous mixed 480 x 320 widgets

| Process | Steady achieved FPS | CPU, one core | Private WS | Private bytes | Threads |
|---|---:|---:|---:|---:|---:|
| renderer | shared | **8.33%** | **14.10 MiB** | 55.45 MiB | 63 |
| mixed A | 57.1-59.6 | 18.44% | 16.50 MiB | 25.14 MiB | 13 |
| mixed B | 56.8-59.6 | 17.60% | 16.62 MiB | 25.28 MiB | 13 |
| mixed C | 57.5-58.5 | 16.35% | 16.56 MiB | 25.22 MiB | 13 |
| **total** | three visible widgets | **60.72%** | **63.78 MiB** | **131.09 MiB** | 102 |

Memory remains in the same class as M4a and the shared renderer stays below
its 10% target, but each mixed widget misses the <=10% CPU target and cadence
occasionally dips below 58 fps. This is a performance miss, not a measurement
artifact: every window was visible and every counted frame completed through
the renderer.

### Audio visualizer and paused clock

| Profile | Presents | CPU, one core | Private WS | Notes |
|---|---:|---:|---:|---|
| hosted mixed audio visualizer | 21.3 fps vs 30 requested | 9.06% | 17.34 MiB | one retained upload |
| its shared renderer | same | 1.88% | 12.68 MiB | audio remained live |
| hosted visualizer after provider silence | no audio frames | **3.75-4.48%** | 16.20 MiB | backend stayed software after its startup race |
| mixed `fps={0}` widget | one initial present only | **0.104%** | 16.46 MiB | 15-second idle interval |
| renderer after that initial present | no further presents | **0.000%** | 13.18 MiB | one retained upload |

The first live audio run had continuously audible Spotify/browser sessions.
A later host restart did reach provider silence and stopped its audio frame
counter at 57, but the hosted widget still consumed 3.75-4.48% of one core.
The direct mixed `fps={0}` control proves the canvas clock and presents are
stopped, so this residual belongs to hosted runtime/IPC idle work rather than
canvas rendering and needs separate profiling. The hosted audio cadence
regression (about 21 fps) is also honest: 30 Hz provider rerenders contend with
the sub-60 canvas timer and need a follow-up scheduler fix.

## Supervision and recovery

The source-missing test registered a temporary checked artifact, observed it
running, deleted the source directory, and sampled status at four and ten
seconds. Both samples reported:

```text
M4b Hybrid Parity  0  -  source missing  registered source path does not exist
```

There was no new PID and no backoff loop. The registration was then removed.

Renderer restart backoff still worked and the mixed widget PID survived both
deliberate renderer kills. The first renderer returned after 1.4 seconds; the
second exercised the five-second backoff and returned after 5.9 seconds. But
the hybrid surface retained its last DirectComposition frame during the gap
instead of visibly repainting through software, and the backend report never
observed `software`. Promotion uploaded retained generations 2 and 3 after the
new renderer connected. This fails the requested live-demotion behavior and
must be fixed before treating renderer crashes as seamless.

A final fork follow-up now detaches the dead DirectComposition visual, restores
the layered-window style with `SWP_FRAMECHANGED`, and skips the invalid retry of
the full mixed packet before pixel fallback. Those are the two necessary
demotion seams and compile/test cleanly. The active hosted recovery run above
still did not produce an observable software frame, so the result remains
classified as failing rather than claiming recovery from code inspection.

Win+D also hid the direct hybrid proof windows on this run, unlike the M4a
result. Ordinary bottom-layer behavior remained correct, but WorkerW parenting
or a software fallback for the desktop layer is still required for reliable
Show Desktop survival.

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

The fork's broad `zig build test` remains at its pre-existing widget-profile
baseline (1414/1451 pass, 6 skipped, 31 failures caused by one-window/view and
reduced canvas capacities). The touched canvas target and all production
Windows/renderer/runtime compilation paths are green; M4b adds no new broad
suite failure.

## Verdict

M4b lands the important memory and damage result: mixed widgets can use the
shared GPU device, retained pixels cross processes once per retained change,
and `fps={0}` is truly idle. It does not yet land the full performance and
resilience gate. The next three fixes, in order, are: plan immediate commands
without re-planning static retained text each frame; decouple 30 Hz provider
rerenders from the canvas timer; and make renderer disconnect switch the DComp
window live to its software bitmap before retrying promotion.
