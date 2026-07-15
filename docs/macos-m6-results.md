# macOS M6 — production retained Metal renderer

Recorded 2026-07-15 on a MacBook Air with Apple M2 (8 cores, 8 GB), macOS
26.5.1 (25F80), arm64, Zig 0.16.0, and Node 23.11.0. The Weaver runtime was
ReleaseFast. This layer implements the architecture selected by
[ADR 0012](adr/0012-macos-in-process-metal-renderer.md); it does not change
Widget source or the public SDK. Native production commit `359f5c9c` is
published as draft [Native PR #5](https://github.com/SunkenInTime/native/pull/5).

## Shipped architecture

Every healthy macOS Widget now requests the in-process retained Metal
compositor regardless of the generated internal `renderBackend` hint. The
Windows interpretation of that hint is unchanged. `WEAVER_FORCE_SOFTWARE=1`
is the measurement/recovery-reference seam.

The Native SDK now:

- compiles `canvas_shaders.metal` to a metallib at build time and embeds it in
  the executable; production contains no `newLibraryWithSource` call;
- owns one process-lifetime device, queue, library, presenter pipeline,
  blend/copy compositor pipelines, sampler, and flat texture;
- keeps the existing binary retained-packet, keyed raster-cache,
  damage/scissor, static-clean parking, and occlusion-heartbeat contracts;
- reuses one bounded CPU raster buffer and at most 16 scratch textures / 32
  MiB of scratch texture capacity per surface;
- keeps backdrop blur's necessary target readback in one surface-owned buffer
  grown only to the largest drawable seen;
- compiles the first-pixel verification readback and deterministic Metal
  fault injector only into automation builds;
- demotes a failed Metal packet to same-frame software pixels, reports the
  backend honestly, and probes recovery after 1, 5, then 30 seconds.

System, Visualizer, and Now Playing remain honestly unavailable as production
Weaver workloads until their public provider implementations land in PRs
10-13. The gate therefore uses Clock, Pomodoro, the retained parity Widget,
the 60 Hz synthetic Widget, and both Native SDK AppKit parity applications.

## Whole-process production cost

`scripts/macos-renderer-bakeoff.py` copied already-built Widgets to isolated
run roots, launched the production runtime, warmed for three seconds, sampled
each process once per second for five seconds, captured `footprint`, `vmmap`,
`lsof`, and `proc_pid_rusage`, then terminated through AppKit's SIGTERM path.
There is no daemon, provider worker, or renderer helper before PR 10, so these
are the complete participating-process totals.

| Workload | Backend | Count | CPU | Physical MB | Threads | FDs | Teardown |
|---|---|---:|---:|---:|---:|---:|---:|
| Clock 1 Hz | Metal composite | 1 | 0.18% | 100.156 | 6.8 | 34 | 11.2 ms |
| Clock 1 Hz | Metal composite | 3 | 0.96% | 302.222 | 23.2 | 102 | 21.5 ms |
| Clock 1 Hz | Metal composite | 10 | 3.24% | 990.537 | 90.2 | 340 | 70.8 ms |
| Clock 1 Hz | forced software | 1 | 0.52% | 94.766 | 6.6 | 34 | 10.5 ms |
| Clock 1 Hz | forced software | 3 | 1.18% | 284.691 | 21.2 | 102 | 37.3 ms |
| Clock 1 Hz | forced software | 10 | 3.44% | 934.078 | 90.2 | 340 | 62.3 ms |
| Mixed real | Metal composite | 3 | 1.00% | 315.919 | 21.2 | 102 | 33.3 ms |
| Mixed real | forced software | 3 | 1.12% | 292.654 | 20.8 | 102 | 32.5 ms |
| Synthetic 60 Hz | Metal composite | 1 | 21.30% | 123.913 | 8.6 | 34 | 10.6 ms |
| Synthetic 60 Hz | Metal composite | 3 | 66.84% | 376.163 | 23.0 | 102 | 34.5 ms |
| Synthetic 60 Hz | forced software | 1 | 99.76% | 107.906 | 8.0 | 34 | 22.7 ms |
| Synthetic 60 Hz | forced software | 3 | 303.18% | 323.898 | 23.0 | 102 | 41.8 ms |

The production choice remains earned where it matters: one active Widget uses
78.6% less CPU than software and three use 77.9% less, at a 16.0 / 52.3 MB
whole-workload footprint premium. Static and mixed CPU are close; the retained
Metal texture cost is explicit. The new production artifact uses 34 file
descriptors per Widget versus 37 in M5.

Against the M5 spike, one active Metal Widget moved from 23.91% / 123.045 MB
to 21.30% / 123.913 MB; three moved from 61.11% / 378.899 MB to 66.84% /
376.163 MB. Short-run CPU is load-sensitive, so these are evidence rather than
a hard regression threshold. The dominant architectural win over software is
unchanged.

The ten-Clock public process counters measured 574.57 interrupt wakeups/s and
28.331 process mJ/s for Metal, versus 575.65 wakeups/s and 97.302 process mJ/s
for software. One 60 Hz Widget measured 109.13 wakeups/s and 149.042 process
mJ/s for Metal, versus 85.07 wakeups/s and 5020.599 process mJ/s for software.
These are `proc_pid_rusage` process counters, not whole-SoC/GPU power claims.

## Startup and hot-path proof

Two consecutive fresh production processes reached the first recorded present
69.0 and 80.2 ms after runner entry. The embedded metallib plus all three
process pipelines loaded in 0.860 and 0.786 ms. The first retained Metal frame
then measured:

| Stage | First process | Immediate repeat |
|---|---:|---:|
| Device + process queue | 596 us | 686 us |
| Embedded metallib + 3 pipelines | 860 us | 786 us |
| Binary packet decode | 29 us | 29 us |
| Retained planning | 13 us | 12 us |
| Composite encode | 420 us | 387 us |
| Drawable wait | 818 us | 766 us |
| Presenter encode | 141 us | 36 us |
| GPU completion | 651 us | 219 us |

`strings` over the final production executable found neither
`newLibraryWithSource` nor `NATIVE_SDK_AUTOMATION_METAL_FAILURES`. It did find
the embedded-metallib and demotion/recovery status strings. Production
presenter traces record `verify_readback=0`.

## Correctness, recovery, and lifecycle

- The default composite dashboard smoke passed resize, binary retained
  packets, pointer input, accessibility, incremental repaint, API state, and
  zero-WebKit-helper assertions. Metal versus the CPU reference differed by at
  most one channel value on stable compared frames.
- The uninstrumented component gallery passed its 100 ms input-to-glass gate.
  With `NATIVE_SDK_GPU_COMPARE=1`, stable frames still differed by at most one,
  while the deliberate 3.7-million-pixel reference redraw/readback added about
  220 ms. That comparator is automation-only and is not treated as production
  latency.
- An automation build refused two composite packets, exercised the binary and
  JSON retries, presented same-frame software pixels, reported
  `software reason=packet-fallback`, emitted a Metal recovery probe, reported
  `packet-success`, and exited 0. The run ended at 121.357 MB, 34 descriptors,
  and 10.6 ms teardown.
- Native `zig build test`, Weaver runtime `zig build test`, root `npm test`,
  and `npm run typecheck` pass. The Native dashboard and component AppKit
  smokes pass in their appropriate pixel or production-latency modes.
- Native `scripts/gate.sh fast 18e9498c` passed root test/validate, all
  frontend/native/mobile example suites, and every calibrated render benchmark.
  The Chromium link check is the pre-existing explicit skip because the local
  CEF SDK layout is absent. Weaver also cross-built the Windows ReleaseFast
  runtime with the CI `web-layer=exclude` / `trace=off` contract.

The 10-minute 60 Hz run recorded 36,410 frame events across 607.8 seconds.
Frame interval p50/p90/p99 was 16.666/16.704/18.270 ms. Four intervals exceeded
25 ms; the 851 ms maximum coincided with the deliberate end-of-run
`footprint`/`vmmap` inspection and is not presented as renderer cadence. Mean
CPU was 23.61%. Physical footprint ended at 123.782 MB (127.567 MB peak), with
34 descriptors, 6-8 threads, zero backend transitions, exit 0, and 22.7 ms
teardown. RSS fell from a 172.687 MB first-minute mean to 86.342 MB in the last
minute rather than growing.

The 10-minute zero-update retained-parity run emitted only three
startup/initial-occlusion/reveal frame events, then fully parked. Mean CPU was
0.006%, with 1.11 interrupt wakeups/s and 0.019 process mJ/s. Physical
footprint ended at 110.265 MB (118.211 MB peak), 34 descriptors, 5-7 threads,
zero backend transitions, exit 0, and 20.9 ms teardown. RSS fell from a
161.845 MB first-minute mean to 68.043 MB in the final minute. This is the
static-clean fast path on a real retained surface, not an empty or minimized
process.

An opaque normal-level AppKit window then fully covered the visible 60 Hz
Widget. The presenter stopped acquiring drawables and emitted 13 logical
`path=occluded` completions at roughly one-second intervals. Removing the
cover triggered an immediate real present and restored 16.7 ms cadence without
a backend transition. The cover and Widget both exited cleanly.

Twenty consecutive production Clock launch/close runs all exited 0. Every run
held 34 descriptors; physical footprint ranged from 95.962 to 100.763 MB and
teardown from 8.85 to 12.13 ms (10.56 ms mean). No renderer transition or
leftover Widget process remained.

## Instruments and physical-environment boundary

The required before/after Instruments capture cannot launch on this machine.
`xcrun xctrace` is killed with exit 137 before it can list templates. The
kernel records the exact AMFI failure:

```text
dynamic: com.apple.dt.InstrumentsCLI disallowed with com.apple.private.tcc.allow entitlement
load code signature error 4 for file "xctrace"
```

The installed tool is Xcode 16.0 (16A242d) on macOS 26.5.1. Its signature
verifies on disk, but this OS rejects the entitlement at execution. The result
retains the unprivileged `proc_pid_rusage`, `footprint`, `vmmap`, stage, frame,
and cache counters instead of pretending they are Instruments captures.

Sleep/wake and external-display reconnect remain physical gates: sleeping the
only unattended machine would sever the run, and only the integrated display
is attached. PR04 already proved all four anchors at Retina 2x and recorded the
same exact hardware boundary. These gates remain `UNVERIFIED`, not falsely
passed or generalized from unit tests.
