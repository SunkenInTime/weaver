# The GPU ledger wall — name the 85 MB

Brief for an agent on Dara's MacBook Pro (`Mac15,6`, Apple M3 Pro, 18 GB,
macOS 26.5.2). This is the successor to the shared-renderer experiment in
`docs/macos-memory-handoff.md`, whose Phase 0 gate stopped that plan; read
its "2026-07-30 correction" section for the full evidence trail. Vocabulary
(receipt, tripwire, landmine) is CLAUDE.md.

## The finding you are chasing

On this machine, on branch `feat/macos-memory-work` (weaver `c099db6`,
native submodule on `macos-memory-shared-renderer-prep` at `6a8e6178`):

- Bare NSWindow + CAMetalLayer + Metal device + one presented frame:
  9.705 MiB mean physical footprint (~1.1 MB graphics ledger).
- Weaver running trivial Myclock: **125.3 MB footprint, of which 85 MB is
  dirty "Owned physical footprint (unmapped) (graphics)" across 33
  regions** (peak 128.3 MB).
- The identical branch state measures 34.265 MiB on a `Mac14,2` M2 Air.

So the wall is not the Metal entry fee (bare probe ~1 MB graphics), not
measurement error (same tools, floors match the Air within ~1.5 MiB), and
not machine-generic (absent on the Air). Something Weaver's renderer does
makes THIS GPU driver retain ~85 MB for a clock. Your job: give that 85 MB
a name — which allocation, which API pattern, which driver behavior. No
architecture decisions until it has one.

## End state

A written receipt in this doc that names what the 85 MB is, demonstrated
by turning it on and off: a change (or workload variation) that moves the
owned-unmapped-graphics ledger by tens of MB, measured live, plus the
recommendation that follows (fix in-process vs shared renderer vs report
as driver behavior). Rendering stays visually correct and tests stay
green throughout; a low number with broken rendering is a failed end
state.

## Evidence-led order

1. **Reproduce first.** From `runtime/`:
   `mise exec zig@0.16.0 -- zig build -Doptimize=ReleaseFast`, then run
   `runtime/zig-out/bin/weaver-widget myclock/dist`, verify the PID started
   after the build finished, and sample `footprint -p <pid>` after a 5 s
   warmup. Expect ~120-125 MB with ~85 MB owned-unmapped-graphics. Record
   the number before touching anything.
2. **Software-candidate discriminator.** Force the software rendering path
   (the prior thread's bakeoff had a `software` candidate; find the forcing
   mechanism in the runtime) and measure. The old thread saw software at
   128.6 MB — if software is still wall-height, the trigger is in the
   CAMetalLayer present loop shared by both paths, not in canvas GPU
   rendering.
3. **Redraw-rate variation.** Myclock ticks at 1 Hz (`timer` +
   `gpu_surface_frame` every second). Compare a static widget (no timer,
   one present) against Myclock: does the ledger hit 85 MB at first present
   or accumulate to a high-water mark? Immediate points at layer/surface
   allocation; accumulating points at drawable/command-buffer pool
   retention.
4. **Machine A/B.** Same widget, same commit, `vmmap --summary` +
   `footprint` on both this machine and the Air; diff the graphics
   categories (here: 85 MB owned-unmapped dirty, IOAccelerator 3.5 MB,
   IOSurface 432 KB). The Air's continuation receipts in the handoff doc
   have its numbers.
5. **Bisect Weaver's Metal usage** until the ledger moves: canvas GPU
   surface allocation, drawable pool configuration, texture/heap allocation
   pattern, `WEAVER_MEMORY_RECEIPT=1` internals. Metal debug/environment
   instrumentation is fair game for diagnosis; nothing diagnostic ships.

## Rules

- Every claimed number: live measurement, multiple samples, recorded here.
- Always verify PID start time > build finish time (stale-PID mixups have
  burned two threads already), and use weaver's status API for the active
  PID when running under weaverd.
- The measurement method that works everywhere: the process's own
  `task_info(TASK_VM_INFO).phys_footprint`, or `footprint`/`vmmap` where
  attach is permitted. On the Air's T3 harness, attach hangs; self-report
  instead.
- Do not start shared-renderer work from this brief. If the name you find
  argues for it, record the receipt and stop; that decision gets made with
  Dara.

## Recorded results (append as you go)

- (pending)
