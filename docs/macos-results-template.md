# macOS M<N> results: <capability>

## Claim and non-goals

State exactly what becomes runnable at this layer and what remains outside it.

## Build identity

- Weaver branch and commit:
- Native SDK branch and commit:
- macOS version and build:
- Hardware and architecture:
- Display arrangement and scaling:
- Zig, Node, Xcode, and SDK versions:
- Relevant System Settings and permissions:
- Starting process IDs:

## Automated verification

| Command | Exit | Result/evidence |
|---|---:|---|

## Computer-use verification

Record the deterministic fixture, before/during/after captures or recording,
timestamps, machine-readable status/log correlation, and restored settings.
Mark an unavailable physical gate `UNVERIFIED` with its exact blocker.

## Whole-application cost ledger

Define every metric and sampling interval. Total host, Widget, renderer,
provider, helper, shared-memory/IOSurface, thread, descriptor, timer, and
wakeup cost; do not report only the process improved by this layer.

| Workload/process | Backend | CPU | Footprint/private/dirty/compressed | Threads/FDs | Wakeups/energy | Frames/latency | Raw evidence |
|---|---|---:|---:|---:|---:|---:|---|

For an optimization, attach matching before/after workloads and Instruments
captures. If the layer makes no performance claim, say so explicitly.

## Failures, risks, and rollback

List actionable failures retried, safe alternatives attempted, remaining
`UNVERIFIED`/`BLOCKED` gates, known risks, and the lowest stack layer that can
be reverted independently.

## Cleanup

- Weaver processes terminated:
- Sockets/endpoints removed:
- Temporary registrations/data removed:
- Reversible desktop settings restored:
- Working trees/submodule clean:
