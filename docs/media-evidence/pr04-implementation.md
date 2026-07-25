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
- Parser tests cover full/empty/non-diff frames, frame-v2 mapping, base64 art
  publication, status, source identifier, position, and duration.
- Lifecycle tests cover a failed helper, one forced empty loss frame,
  unavailable diagnostics, bounded restart state, idle teardown, recovery,
  command IDs, seek microseconds, duration clamping, and false ack on process
  failure.
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

Performance claim: explicitly declined. Windows code paths remain green, but
this run has no attended execution of Weaver's macOS adapter and therefore no
honest macOS process-cost measurement.
