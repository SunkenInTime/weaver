# macOS M8 — subscription-driven CPU and memory providers

Recorded 2026-07-15 on a MacBook Air with Apple M2 (8 cores, 8 GB), macOS
26.5.1 (25F80), arm64, Zig 0.16.0, Node 23.11.0, and Xcode 16.0 (16A242d).
The measured implementation is Weaver commit `e8708a9` on
`macos/11-cpu-memory-providers`; Native SDK remains `359f5c9c`. Runtime and
host artifacts were ReleaseFast.

## Contract and implementation

Widget source and the SDK shape are unchanged:

- `cpu`: `{ percent, perCore }` once per second, with aggregate and each
  logical core independently bounded to 0–100;
- `memory`: `{ usedMb, totalMb, percent }` once per second. `usedMb` means
  installed physical memory minus free and inactive/reclaimable pages, and
  `percent` is that ratio.

The macOS sampler uses public `host_processor_info`, `host_statistics64`,
`host_page_size`, and `sysctlbyname("hw.memsize")`. It initializes only after
a live CPU/memory subscriber exists and takes one machine snapshot per second
regardless of subscriber count. The host serializes one portable JSON frame,
compares it byte-for-byte with the previous frame, and fans the same bytes to
each interested per-Widget UDS. Initial state is always sent; unchanged values
are suppressed. `time` remains SDK-local. Audio and media remain explicitly
unimplemented at this layer.

## Verification

| Command | Exit | Result/evidence |
|---|---:|---|
| `cd host && zig build test && zig build -Doptimize=ReleaseFast` | 0 | live Mach sampler bounds, portable exact JSON fields/equality, supervisor, and macOS host pass |
| `cd runtime && zig build test && zig build -Doptimize=ReleaseFast` | 0 | UDS line framing/bounded queue and provider dispatch compile/test pass |
| `npm run typecheck && npm test` | 0 | SDK and CLI contract suite passes |
| `node cli/test/macos-host-smoke.mjs` | 0 | zero collection, two-Widget fan-out, exact endpoints, applied frames, concurrent unsubscribe, no post-unsubscribe samples, plus PR10 lifecycle regression pass |
| `python3 scripts/macos-provider-cost.py --sample-seconds 5 --output docs/macos-m8-data.json` | 0 | complete host + 0/1/3 System workload ledger, isolated HOME, automatic cleanup |

The physical System run published `systemSubscribers: 1`,
`systemSampleCount: 2`, and `systemFrames: 2`; the Widget log then recorded
`widget provider frames applied count=2`. Its live status reported Metal,
47.65 MiB process physical footprint, 0.15% of one core, and eight threads.
The fan-out smoke launched two distinct System Widgets, observed two private
provider sockets, one shared sample stream, at least four initial delivered
frames, and application logs from both runtimes. Concurrent uninstall removed
both endpoints; after another 2.2 seconds the sampler count was unchanged.

The serializer test pins the exact `percent`, `perCore`, `usedMb`, and
`totalMb` names and one-decimal numeric form. The live sampler test takes two
Mach snapshots and proves every utilization value and memory ratio is bounded.
The host status counters are deliberately machine-readable: subscriber count,
sampler calls, and successful system frames.

## Whole-application cost

`scripts/macos-provider-cost.py` launched one production host in an isolated
HOME, then measured the same host with zero, one, and three production System
Widgets. After warmup it sampled `ps` once per second for five seconds. CPU is
percent of one core summed across every participating process. Memory is RSS,
not the `proc_pid_rusage` physical-footprint metric used in the renderer
documents, and is not compared to it. Full per-process samples are in
[`macos-m8-data.json`](macos-m8-data.json).

| Workload | Processes | CPU mean (one core) | RSS mean | Threads mean | Sampler delta | Frame delta |
|---|---:|---:|---:|---:|---:|---:|
| Host, zero subscribers | 1 | 0.14% | 1.441 MiB | 2.0 | 0 | 0 |
| Host + one System Widget | 2 | 1.96% | 156.059 MiB | 9.4 | 4 | 8 |
| Host + three System Widgets | 4 | 3.96% | 428.816 MiB | 24.8 | 4 | 24 |

The provider collector itself does not scale with subscriber count: both
active workloads took four samples during the captured boundary, while frame
delivery scaled from eight to twenty-four exactly with one versus three
subscribers. In the three-Widget run the host averaged 0.18% of one core and
about 2.02 MiB RSS; the isolated zero-subscriber host made zero sampler calls.
The full System process cost remains dominated by the crash-isolated AppKit +
QuickJS Widget processes, consistent with ADR 0012.

## Physical boundary, risks, and cleanup

Sleep/wake remains `UNVERIFIED`: sleeping the only unattended machine can
sever the run, and the brief forbids inferring the result. Rapid live
subscribe/unsubscribe, host/Widget crash recovery, and restart reinitialization
are automated. ScreenCaptureKit recording remains blocked by TCC error `-3801`;
the live gate therefore correlates real PIDs, sockets, status counters, and
runtime application logs rather than claiming a new screenshot.

Intel execution remains CI-only. Mach tick counters are 32-bit, so the sampler
uses wrapping deltas. A failed public OS sample emits no fabricated frame and
retries on the next subscribed interval. Rollback is this PR: PR10's host and
transport continue to work with CPU/memory honestly silent.

All measurement Widgets, host processes, provider sockets, isolated
registrations/HOME roots, and runtime locks were removed. No desktop setting
or permission changed.
