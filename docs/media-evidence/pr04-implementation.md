# Media PR 04 implementation evidence

Date: 2026-07-25

## Evidence boundary

The attended spike in [`pr04-mac-spike.md`](pr04-mac-spike.md) proves the
`/usr/bin/perl` adapter route with a real Spotify frame and delivered pause
command. It does **not** prove this Weaver implementation produced a frame,
cached artwork, delivered a command, recovered from helper loss, or passed
Developer-ID distribution checks.

Those Weaver implementation checks are **UNVERIFIED (needs attended Mac)**.
The two Spotify screenshots were opened and viewed during this implementation
run; they show the matching `Satellites` track playing at 0:37 and paused at
0:51. They are route evidence, not a Weaver visual gate.

## Locally verified

- The exact upstream adapter v0.7.6 commit
  `3ac3d4bdf862c7b5399b4fba4df5689f5c38609a` and BSD-3-Clause license are
  vendored under `host/assets/mediaremote-adapter`.
- Windows host behavior remains green after the shared art cache was made
  portable.
- Parser tests cover full/empty/non-diff frames, blank-title sessions,
  unknown playback state, timestamped frame-v2 mapping, 1 Hz position
  advancement, source identifier, position, and duration.
- A real 300×300 PNG fixture passes the macOS decode/downsample/PNG path and
  publishes within the shared image budget. Invalid base64 is an adapter
  protocol failure rather than a silent art omission.
- Lifecycle tests cover a failed helper, one forced empty loss frame,
  unavailable diagnostics, bounded restart state, idle teardown, recovery,
  command IDs, seek microseconds, duration clamping, strict EOF residuals,
  30-second stability reset, the 15.4 floor, and channel rejection on process
  failure. Exit 2 alone represents an OS decline.
- Each transport-capable widget owns one FIFO command worker. The host
  supervision loop only authorizes/enqueues and later writes completed acks,
  so a helper timeout cannot stall provider delivery, supervision, reload, or
  shutdown handling. Metadata teardown escalates TERM to KILL after a bounded
  grace window.
- The release audit passes and the Native SDK submodule remains pinned.

Final local commands:

```text
npm test
PASS (63/63)

npm run typecheck
PASS

npm run audit:release
PASS

node cli/bin/weaver.js check examples/now-playing
PASS

node cli/bin/weaver.js check examples/noro-shell
PASS

node cli/test/example-surface-smoke.mjs
PASS (8 portable example surfaces)

runtime: zig build test -Dweb-layer=exclude -Dtrace=off
PASS

runtime: zig build -Dweb-layer=exclude -Dtrace=off
PASS

host: zig build test
PASS

host: zig build
PASS

zig test host/src/providers_macos.zig -I host/src \
  -target aarch64-macos.14.2 -fno-emit-bin
PASS (semantic compile only)

zig test host/src/macos_host.zig -I host/src \
  -target aarch64-macos.14.2 -fno-emit-bin
PASS (semantic compile only)
```

Post-review teardown hardening (2026-07-25): widget reload/crash/uninstall now
marks the per-widget command executor stopped and transfers ownership to its
detached worker without joining on the supervision loop. The worker
self-releases after the already-bounded 2.5-second helper result; the provider
tracks every worker, and final process shutdown allows one explicit
three-second drain before failing closed. A deterministic 300 ms in-flight
command seam verifies that supervision-side teardown returns in under 100 ms.
Both macOS source files pass the semantic cross-compile above; runtime behavior
remains **UNVERIFIED (needs attended Mac)**.

Performance claim: explicitly declined. Windows code paths remain green, but
this run has no attended execution of Weaver's macOS adapter and therefore no
honest macOS process-cost measurement.

## Attended-Mac re-verification required

The next attended session must run Weaver's implementation (not the standalone
spike) and verify:

1. real-player full metadata, blank-title session handling, status changes,
   and smooth 1 Hz elapsed-time advancement;
2. 300×300+ artwork renders from the normalized cache with malformed artwork
   producing one empty/unavailable loss frame and recovery;
3. play, pause, next, previous, a verified seek within ±2000 ms, and a
   no-session seek resolving `false`;
4. missing helper/framework, timeout, and signal death rejecting rather than
   resolving `false`;
5. partial-record EOF, helper crash, quit/relaunch, exponential backoff, and
   TERM-to-KILL teardown;
6. no helper spawn and unavailable diagnostics on macOS 15.3 or older, plus
   direct execution at the 15.4 floor;
7. Developer-ID hardened-runtime signing, secure timestamp, notarization,
   quarantine, and Gatekeeper launch.
