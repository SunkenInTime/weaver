# macOS M5 — whole-process renderer bakeoff

Recorded 2026-07-15 on a MacBook Air with Apple M2 (8 cores, 8 GB), macOS
26.5.1 (25F80), arm64, Zig 0.16.0, and Node 23.11.0. The production runtime
was ReleaseFast. Native SDK spike commit `18e9498c` is published in draft
[Native PR #4](https://github.com/SunkenInTime/native/pull/4); the Weaver
measurement branch pins that exact commit. PR 06 changes no production
renderer default.

## Candidate contracts

The labels describe what the existing code actually does:

- **software**: the CPU reference rasterizer produces damage-aware RGBA8
  pixels; the AppKit surface still uses its minimal Metal texture presenter to
  put those pixels on a `CAMetalLayer`.
- **metal-hybrid**: the runtime emits compact binary retained packets; AppKit
  decodes them to bounded Objective-C collections, retains the command list,
  rasterizes commands with Core Graphics, uploads dirty texture regions, and
  presents through Metal.
- **metal-composite**: the same binary/retained path rasterizes non-native
  command content into cached or bounded scratch textures, then Metal composes
  quads into the retained canvas target before the presenter pass. It is not a
  fully Metal-native vector renderer.

Every candidate is in the crash-isolated Widget process. There is no host,
daemon, or renderer helper in this layer, so the table totals are the complete
running process set available before PR 10 rather than a renderer-only slice.

## Workloads and method

`scripts/macos-renderer-bakeoff.py` copies already-bundled production Widgets
into a run-owned ignored directory, changes only internal backend selection and
placement, launches 1/3/10 processes, waits five seconds, then takes ten
one-second `ps` samples. `/usr/bin/footprint`, `/usr/bin/vmmap -summary`,
`lsof`, and `proc_pid_rusage(RUSAGE_INFO_V6)` provide memory, descriptors,
wakeups, instruction/cycle, and per-process energy counters. SIGTERM enters the
AppKit graceful termination path; all measured processes exited 0.

- Static scaling uses the real Clock. It changes at 1 Hz, so this is a quiet
  steady-state workload, not a zero-update claim.
- Mixed scaling cycles the real Clock, real idle Pomodoro, and the static
  retained/canvas parity Widget. Count 3 is one of each; count 10 repeats that
  cycle.
- Active scaling uses the real 480 x 320 `m4b-synthetic` Widget at 60 Hz, with
  one and three processes.

System and Visualizer cannot be honest direct-run members yet: their CPU,
memory, and audio provider endpoints arrive in PRs 10–12. Substituting fake
provider data would make the “real Widgets” claim less honest, so this layer
records the exact boundary and uses the available production Widgets.

## Whole-process scaling

CPU is percent of one core, summed across all processes and averaged over ten
samples. Footprint is the sum of Apple `phys_footprint` bytes after sampling,
shown in decimal MB. Threads are the summed sample mean; FDs are the summed
post-sample count.

| Workload | Candidate | Count | CPU | Physical MB | Threads | FDs |
|---|---|---:|---:|---:|---:|---:|
| Clock 1 Hz | software | 1 | 0.35% | 94.766 | 8.1 | 37 |
| Clock 1 Hz | software | 3 | 0.85% | 284.036 | 21.4 | 111 |
| Clock 1 Hz | software | 10 | 6.71% | 930.866 | 75.5 | 370 |
| Clock 1 Hz | metal-hybrid | 1 | 0.25% | 96.110 | 8.0 | 37 |
| Clock 1 Hz | metal-hybrid | 3 | 0.65% | 290.901 | 18.3 | 111 |
| Clock 1 Hz | metal-hybrid | 10 | 2.74% | 944.154 | 74.7 | 370 |
| Clock 1 Hz | metal-composite | 1 | 0.26% | 99.894 | 6.2 | 37 |
| Clock 1 Hz | metal-composite | 3 | 0.76% | 302.140 | 19.5 | 111 |
| Clock 1 Hz | metal-composite | 10 | 2.73% | 989.505 | 73.7 | 370 |
| Mixed real | software | 3 | 0.96% | 291.622 | 19.0 | 111 |
| Mixed real | software | 10 | 3.80% | 953.591 | 72.1 | 370 |
| Mixed real | metal-hybrid | 3 | 0.95% | 310.463 | 19.4 | 111 |
| Mixed real | metal-hybrid | 10 | 2.66% | 1000.924 | 72.0 | 370 |
| Mixed real | metal-composite | 3 | 0.89% | 308.497 | 18.8 | 111 |
| Mixed real | metal-composite | 10 | 2.79% | 1028.679 | 73.4 | 370 |
| Synthetic 60 Hz | software | 1 | 98.99% | 108.086 | 8.0 | 37 |
| Synthetic 60 Hz | software | 3 | 302.85% | 324.373 | 23.0 | 111 |
| Synthetic 60 Hz | metal-hybrid | 1 | 34.74% | 120.489 | 11.0 | 37 |
| Synthetic 60 Hz | metal-hybrid | 3 | 73.98% | 361.139 | 34.0 | 111 |
| Synthetic 60 Hz | metal-composite | 1 | 23.91% | 123.045 | 8.0 | 37 |
| Synthetic 60 Hz | metal-composite | 3 | 61.11% | 378.899 | 24.1 | 111 |

The 10-Clock software CPU outlier repeated at 4.67% in a shorter independent
run; hybrid and composite repeated at 3.13% and 3.25%. The decision uses the
longer samples but treats quiet multi-process CPU as load-sensitive rather than
a hard regression threshold.

Active one-process VM summaries make the resource delta concrete:

| Candidate | Dirty | Swapped/compressed | IOAccelerator resident | IOSurface resident | CG image resident |
|---|---:|---:|---:|---:|---:|
| software | 103.1 MB | 0 KB | 5.552 MB | 7.200 MB | 36.0 MB |
| metal-hybrid | 114.5 MB | 0 KB | 5.552 MB | 7.200 MB | 36.0 MB |
| metal-composite | 117.5 MB | 0 KB | 14.4 MB | 7.200 MB | 36.0 MB |

The shared-service question therefore has a measured answer: at ten quiet
Widgets roughly 93–103 MB and 37 descriptors recur per crash-isolated runtime,
while the shareable Metal/IOSurface delta is single-digit to low-teens MiB per
process. A service cannot remove QuickJS, AppKit, the Widget window, or the
minimal per-window presenter; it would add a process, IOSurface transport,
synchronization, fallback, and input/window failure states. That bill does not
warrant an IOSurface service proof or shared window owner in PR 06.

## Wakeups and energy counters

The independent counter runs use a roughly five-second delta. “Wakeups/s” is
summed interrupt wakeups from `proc_pid_rusage`; “mJ/s” is its summed
`ri_energy_nj` delta, not a whole-SoC/GPU power claim.

| Workload | Candidate | Count | Wakeups/s | Process energy mJ/s |
|---|---|---:|---:|---:|
| Clock 1 Hz | software | 10 | 577.14 | 71.554 |
| Clock 1 Hz | metal-hybrid | 10 | 573.56 | 23.221 |
| Clock 1 Hz | metal-composite | 10 | 567.73 | 29.109 |
| Synthetic 60 Hz | software | 1 | 124.78 | 4965.233 |
| Synthetic 60 Hz | metal-hybrid | 1 | 110.58 | 184.508 |
| Synthetic 60 Hz | metal-composite | 1 | 83.28 | 144.453 |
| Synthetic 60 Hz | software | 3 | 331.47 | 15051.751 |
| Synthetic 60 Hz | metal-hybrid | 3 | 325.95 | 712.669 |
| Synthetic 60 Hz | metal-composite | 3 | 334.08 | 506.738 |

`powermetrics --show-process-energy` would provide the broader SoC attribution
but exited exactly `powermetrics must be invoked as the superuser`; the
unattended authority does not include a password. The public unprivileged
`proc_pid_rusage` counters are retained as the narrower evidence. Instruments
Energy/Metal System Trace remains a PR 07 physical-performance gate.

## Stage attribution

Native PR #4 adds `NATIVE_SDK_RENDERER_BAKEOFF_TRACE=1`. Disabled production
runs take only cached boolean branches; timestamps and stderr writes disappear.
One traced 60 Hz composite run recorded:

| Stage | First | Warm p50 | Warm p90 |
|---|---:|---:|---:|
| Resource init (default device + per-view queue) | 634 us | — | — |
| Runtime composite shader/pipeline compilation | 2123 us | — | — |
| Binary packet decode | 108 us | 187 us | 237 us |
| Retained edit/dirty planning | 31 us | 299 us | 382 us |
| Composite command encode | 396 us | 61 us | 83 us |
| Presenter command encode | 285 us | 17 us | 23 us |
| Drawable wait | 822 us | 19 us | 25 us |
| GPU completion | 445 us | 508 us | 902 us |
| Whole synchronous app-loop dispatch | 2535 us | 1623 us | 3734 us |

The production runtime frame profiler recorded the upstream construction and
host boundaries in a separate 183-frame automation run:

| Runtime stage | p50 | p90 | Maximum |
|---|---:|---:|---:|
| Rebuild | 12 us | 14 us | 16 us |
| Layout | 9 us | 10 us | 12 us |
| Reconcile | 24 us | 28 us | 32 us |
| Emit | 33 us | 37 us | 42 us |
| Accessibility | 4 us | 4 us | 5 us |
| Plan | 64 us | 72 us | 77 us |
| Patch | 21 us | 23 us | 24 us |
| Encode | 8 us | 9 us | 10 us |
| Present | 3145 us | 3524 us | 3728 us |
| Host decode | 227 us | 237 us | 247 us |
| Host draw | 2929 us | 3266 us | 3465 us |
| Frame interval | 16,660 us | 17,667 us | 18,412 us |

That run's first-frame metric was 0.560 ms. The independent Native trace saw
176 binary packets and zero JSON packets.
Clean retained frames return before decoding and emit
`stage=static_clean_fast_path`. The production first-frame 256-byte readback
reported `verify_readback=1` once and `verify_readback=0` thereafter.
Incremental/full comparison, screenshot dumps, and repeated verification
readbacks remain behind their separate explicit diagnostic environment flags.

The traced active cadence had a 16.665 ms median and 17.980 ms p90 between
runtime surface-frame events. The maximum was contaminated by the deliberate
`footprint`/`vmmap` inspection and is not used as a cadence claim.

## Precompiled library and resource-lifetime proof

The fork spike compiles the presenter/compositor entry points with public
`xcrun metal` + `metallib`, loads them through `MTLDevice.makeLibrary(URL:)`,
and creates one process cache (device, command queue, library, two pipelines,
sampler) plus one retained canvas and three fixed upload buffers per surface.

| Surfaces | Runtime source compile total | Metallib load | Process cache init | Per-surface create | Declared canvas + upload bytes |
|---:|---:|---:|---:|---|---:|
| 1 cold | 283,996 us | 151 us | 14,301 us | 183 us | 2,457,600 |
| 3 warm | 1,669 us | 101 us | 541 us | 105 / 38 / 35 us | 7,372,800 |
| 10 warm | 1,695 us | 79 us | 464 us | 86 then 21–35 us | 24,576,000 |

Driver caches make later source compiles much cheaper, but shipping source
compilation still makes cold startup depend on that external cache. PR 07 will
ship the metallib and process-lifetime immutable cache. Weaver owns one surface
per process, so this does not pretend to share resources across Widget failure
boundaries.

Two consecutive production synthetic launches with
`NATIVE_SDK_WINDOW_TIMING=1` reached first packet submission in 76.4 and 83.0
ms from runner entry and the next surface completion in 196.4 and 198.5 ms.
The dashboard smoke runtime's frame metric recorded 0.434 ms from its first
frame request to completion on one warm automation run; the separately sampled
production frame profile above recorded 0.560 ms. These metrics name different
boundaries deliberately; none is mislabeled as launch-to-visible glass.

## Pixel, API, input, and teardown parity

`NATIVE_SDK_GPU_COMPOSITE=1 NATIVE_SDK_GPU_COMPARE=1
NATIVE_SDK_SMOKE_BUDGET_MS=1000 zig build test-gpu-dashboard-smoke` passed the
real AppKit retained-packet, resize, pointer-input, accessibility, incremental,
and no-WebKit-helper gates. Composite versus CPU reference differed by at most
one channel value on 18 of 3,868,800 pixels; incremental recomposition recorded
zero mismatches. The hybrid path uses the same CPU raster bytes before upload,
and the forced-software path is the reference those tests compare.

All measured processes terminated through SIGTERM in 10–79 ms and exited 0.
No helper renderer, socket, provider endpoint, or persistent registration was
created.

## Decision

[ADR 0012](adr/0012-macos-in-process-metal-renderer.md) selects one in-process
binary/retained Metal composite default for every healthy macOS Widget and the
damage-aware software renderer as reference and live fallback. Choice is not
adaptive; no shared renderer/window owner is required. The 60 Hz CPU win earns
the small memory delta, while one obvious healthy path avoids dual-backing
transition policy. PR 07 implements this completely; PR 06 only records the
decision and measurement seams.
