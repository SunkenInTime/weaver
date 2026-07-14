# M4a results: shared GPU renderer process

M4a implements [ADR 0010](adr/0010-shared-gpu-renderer-process.md). One
`weaver-renderer.exe` owns the hardware D3D11 device and the M3c instanced-SDF
pipeline. GPU widget processes retain their own HWND, input path, JavaScript,
and frame scheduler, but do not create a D3D device or import `d3d11.dll` or
`dxgi.dll`.

The three simultaneous 480 x 320, 60 fps proof widgets are captured in
[m4a-three-visualizers.png](m4a-three-visualizers.png). Their rounded corners
remain per-pixel transparent over the wallpaper.

## Architecture that landed

- The Native SDK fork is on `weaver-fork-renderer` at `bd9d820e`. Its existing
  NSGP decoder and instanced draw pipeline now support both the retained M3c
  presenter and a shared-renderer surface; the shader/parser were not copied.
- The renderer creates one hardware-only D3D11 device. Each connection gets a
  `DCompositionCreateSurfaceHandle` and a three-buffer flip-sequential
  swapchain created through
  `IDXGIFactoryMedia::CreateSwapChainForCompositionSurfaceHandle`.
- The renderer duplicates that kernel handle into the widget process. The
  widget creates `IDCompositionDesktopDevice` with a null rendering device,
  imports the handle with `CreateSurfaceFromHandle`, and binds it to its HWND.
  This is the Windows 11 path that avoids opening a D3D device in every widget.
- NSGP travels over one duplex named-pipe connection per GPU widget. One
  request has one completion reply; the reply is the existing frame-completion
  signal. The renderer serializes its immediate context in FIFO order and uses
  nonblocking composition-surface presents. The widget remains the pacing
  authority.
- A renderer disconnect makes the same frame use the M3a software pixel path.
  The client remains alive and retries its pipe connection on later frames, so
  promotion back to GPU is live and does not restart widget logic.
- Animated surface deadlines use dynamically loaded one-shot multimedia
  timers. The old UI `SetTimer` path delivered a quiet three-widget run at only
  57.3-57.8 fps; precise deadlines produce 60 fps without increasing the
  requested cadence. Already-due work still posts directly to the app loop.
  Static/software widgets never load `winmm.dll` or arm this clock.
- `weaverd` starts the renderer only when an enabled artifact says
  `renderBackend: "gpu"`, uses 1/5/30 second renderer restart backoff, stops it
  after the last GPU registration exits, and includes a `renderer` row plus a
  live BACKEND and thread count in status. `WEAVER_FORCE_SOFTWARE=1` suppresses
  the renderer completely.

The widget executable's import scan contains `dcomp.dll` and no `d3d11.dll`
or `dxgi.dll`. The widget-side binding therefore pays DirectComposition's
window/visual cost, not the graphics-driver device cost.

## Performance

Windows 11, ReleaseFast, visible desktop-layer windows, real completed
presents. CPU is `TotalProcessorTime` over 15 seconds as percent of one logical
core. Private WS is
`Win32_PerfFormattedData_PerfProc_Process.WorkingSetPrivate`; private bytes are
from `Get-Process.PrivateMemorySize64`.

### Three 480 x 320 synthetic visualizers at 60 fps

| Process | Achieved FPS | CPU, one core | Private WS | Private bytes | Threads |
|---|---:|---:|---:|---:|---:|
| renderer | shared across all three | **9.17%** | **13.66 MiB** | 53.68 MiB | 62 |
| Viz A | 60.19 | 9.58% | **16.69 MiB** | 25.29 MiB | 9 |
| Viz B | 60.18 | 8.54% | **16.75 MiB** | 25.35 MiB | 9 |
| Viz C | 60.18 | 9.58% | **16.61 MiB** | 25.21 MiB | 9 |
| **Total** | all three at cadence | **36.87%** | **63.71 MiB** | **129.53 MiB** | 89 |

Each FPS value is based on repeated renderer intervals of 300 completed
presents in 4.984-5.000 seconds, not a JS callback count. The renderer is well
below its 20% target, and each widget is below the 22 MiB private-WS target.
Three per-process M3c devices would have been about 255.7 MiB private WS and
roughly 195 graphics-driver threads on this machine.

The full-system CPU bill is higher than three times only the M3c presenter
number: widget-side JS command production, the precise timer callback, pipe
copying, and completion dispatch remain per process. Memory is now shared;
transport/command-production CPU is the next honest optimization target.

### One 480 x 320 visualizer

| Process | Achieved FPS | CPU, one core | Private WS | Private bytes | Threads |
|---|---:|---:|---:|---:|---:|
| renderer | shared process | 2.92% | 13.60 MiB | 53.56 MiB | 58 |
| widget | 60.18-60.19 | 9.38% | 12.33 MiB | 20.86 MiB | 5 |
| **Total** | | **12.30%** | **25.93 MiB** | **74.42 MiB** | 63 |
| M3c one-process baseline | ~59.0 | 8.96% | 85.24 MiB | 133.61 MiB | ~67 |

The one-widget split is not a memory regression: it saves 59.31 MiB private WS
and 59.19 MiB private bytes versus M3c. It does cost about 3.3 points of one
core for the process/pipe boundary in this synthetic workload.

`weaver status` during the three-widget proof (its `PRIVATE` column is the
existing rolling `PROCESS_MEMORY_COUNTERS_EX.PrivateUsage`, i.e. private
bytes, not the private-WS counter used above):

```text
NAME       PID    BACKEND  PRIVATE  CPU    THREADS  UPTIME  STATE
renderer   31584  gpu      53.7 MB  8.9%   62       2m12s   running
M4A Viz A  2888   gpu      24.9 MB  10.3%  8        2m12s   running
M4A Viz B  25948  gpu      25.0 MB  10.5%  8        2m12s   running
M4A Viz C  57484  gpu      24.9 MB  10.0%  8        2m12s   running
```

Adding the thread column initially made weaverd expensive because one full
system thread snapshot was taken per row. It now takes one snapshot, fans it
out, and caches it for 30 seconds. With three widgets, a 15-second interval
that crossed one refresh measured 0.94% and 1.64 MiB private WS; a steady
10-second interval between refreshes measured 0.16%.

## Crash and fallback proof

The second deliberate renderer kill exercised the 5-second backoff while all
three widgets were visible:

```text
  151 ms  backend files: software,software,software
 1587 ms  status rows:   software,software,software
 5691 ms  backend files: gpu,gpu,gpu (new renderer connected)
```

Widget PIDs before and after were the same set:
`30472, 60300, 31700`. The processes continued through the gap on the software
presenter, then all three imported replacement surfaces. The first-crash path
uses the shorter one-second backoff; the deliberately slower second path still
returned to GPU comfortably inside ten seconds.

## Windowing and regressions

- A shared-GPU visualizer stayed `visible=True, iconic=False` across Win+D.
  It retained per-pixel transparency and the existing desktop-bottom behavior.
- With only Clock and Pomodoro installed, no renderer process or renderer
  status row existed. Both reported `software`.
- A direct native-child click changed Pomodoro's slider to 13 minutes; a second
  click started it and the visible value advanced from 13:00 to 12:56 with the
  button reading `Pause`. This exercises the same child HWND input dispatch as
  M2a without involving the renderer.
- The checked-in audio visualizer received live WASAPI loopback data
  (`audioPipeFrames: 221`, `audioSilent: false`) and promoted to shared GPU as
  soon as nonzero bars produced a packet.
- Under `WEAVER_FORCE_SOFTWARE=1`, Clock, Pomodoro, and Visualizer all reported
  `software` and no `weaver-renderer` process existed.

## Build and verification

From a clean checkout, with the submodule initialized:

```powershell
$env:PATH = 'E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0;' + $env:PATH
git submodule update --init runtime/native-sdk
npm install

cd renderer
zig build -Doptimize=ReleaseFast
cd ..\runtime
zig build -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off
cd ..\host
zig build -Doptimize=ReleaseFast
cd ..
```

Verification results:

- `npm run typecheck`: pass.
- `npm test`: pass, 7/7.
- `runtime: zig build test`: pass.
- `runtime` ReleaseFast Windows build: pass; imports DComp but not D3D/DXGI.
- `renderer` ReleaseFast build: pass.
- `host: zig build test` and ReleaseFast build: pass.
- The fork's production Windows client and renderer units compile through the
  runtime and renderer builds. The pre-existing widget-profile limitation on
  the fork's broad desktop test targets remains as documented in M3a/M3c.

## Honest caveats

- The transport is a synchronous named-pipe packet/reply per frame, not the
  shared-memory ring from the architecture's optional branch. It is simple,
  reliable, and meets M4a's targets; it is also the obvious source of the
  remaining per-widget CPU overhead.
- The renderer creates one server thread per connected widget. Driver threads
  remain centralized, but connection-thread count still scales linearly.
- DirectComposition surface memory is reported differently by Windows:
  private bytes charge much of the swapchain allocation to the renderer and
  imported composition bookkeeping to widgets. Private WS is the comparison
  used for the hard process targets.
- During a renderer gap the software presenter must rasterize full canvas
  frames again. The fallback is visually continuous, but CPU temporarily
  returns to M3a-class cost until promotion.
- Renderer shutdown after the last GPU widget is currently process
  termination rather than a protocol-level graceful command. The renderer has
  no persistent state, so this is mechanically safe, but an explicit shutdown
  event would make diagnostics cleaner.
