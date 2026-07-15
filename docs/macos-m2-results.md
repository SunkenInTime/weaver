# macOS M2 — portable runtime and direct software Clock

Recorded 2026-07-15 on a MacBook Air with Apple M2 (8 cores, 8 GB), macOS
26.5.1 (25F80), arm64, Zig 0.16.0, and Node 23.11.0.

## Claim

`weaver-widget` now builds and runs directly on macOS without the daemon. The
bundled Clock uses the CPU reference renderer, presents through the pixel path,
persists storage under the native application-support root, rotates its native
log, and shuts down cleanly.

This is deliberately the PR 03 bootstrap contract. HTTPS transport remains an
explicit failure on macOS until PR 05, and `weaver dev` is not claimed here.

## Newly discovered Native SDK dependency

The first physical run selected CPU pixels inside Weaver, but the AppKit host
hard-coded every frame report to `metal`/`opaque`. Treating that as merely a
logging problem would make backend status dishonest. Native SDK commit
`673c07f4` carries the requested backend and alpha mode through the AppKit ABI
and makes a declared software surface bypass available packet services. It is
published as stacked draft [Native SDK PR #2](https://github.com/SunkenInTime/native/pull/2),
based on the AppKit windowing PR.

The AppKit view still uses its compositor-facing layer to put CPU-produced
pixels on screen. `software` describes the selected renderer, while `pixels`
describes the presenter path; neither is reported as Metal packet rendering.

## Runtime seams

- PID, monotonic time, wall time, data root, log root, and provider endpoint
  resolve through `runtime/src/platform/root.zig`.
- macOS data lives under `~/Library/Application Support/Weaver`; logs live
  under `~/Library/Logs/Weaver`.
- logging uses portable append I/O, UTC timestamps, a 1 MiB threshold, and one
  `.old` backup.
- the Windows monitor bridge and named-pipe provider transport are isolated in
  Windows modules. The macOS provider is inert only when no endpoint is
  supplied and rejects a supplied unsupported endpoint.
- URL parsing and origin tests remain platform-neutral. The macOS request
  transport returns `request_failed` rather than pretending to send traffic.

## Direct Clock gate

Build and launch:

```text
node cli/bin/weaver.js bundle examples/clock
cd runtime
zig build -Doptimize=ReleaseFast
cd ..
./runtime/zig-out/bin/weaver-widget examples/clock/dist
```

The production process was PID 96604. `CGWindowListCopyWindowInfo(.optionAll)`
reported its on-screen Clock window at `(735, 280)`, `240 x 110`, layer
`-2147483604`. Its native log reported:

```text
widget renderer selected=software presenter=pixels
widget host surface backend=software
widget presenter path=pixels
```

The correlated automation snapshot reported:

```text
gpu_backend=software
gpu_alpha_mode=premultiplied
gpu_present_path=pixels
gpu_nonblank=true
gpu_sample=0xdb11141c
canvas_commands=7
```

![Direct software Clock on macOS](macos-m2-clock.png)

The image is the deterministic AppKit surface capture emitted by the Native
SDK automation endpoint, not an OS screen-recording capture. The CG window
inventory above separately confirms that the same production window was
on-screen. Screen Recording permission remains unavailable to this unattended
process, as recorded in the PR 02 results.

## Persistence, rotation, and shutdown

A temporary `StorageProbe` Widget wrote `{"generation":1}` on its first run.
The second direct run read that exact value and wrote `{"generation":2}` to:

```text
~/Library/Application Support/Weaver/storage/e850359e7b31fd54.json
```

Both runs exited 0 after `NSRunningApplication.terminate()`. The production
Clock did the same; its terminal event sequence ended with `stop` followed by
`window_closed`, and the process exited 0.

For the rotation gate, `Clock.log` was pre-sized to 1,100,000 bytes. The next
launch preserved that exact file as `Clock.log.old` and created a fresh current
log. The synthetic probe, storage value, and oversized backup were removed
after recording the result.

## Cost ledger

The Clock updates once per second, so this is a steady-state 1 Hz measurement,
not a truly static idle surface. Ten `top` samples at one-second intervals were
`0.0, 0.6, 0.5, 1.2, 0.7, 1.1, 1.3, 0.8, 0.9, 0.8` percent of one core: mean
`0.79%`. The process held 5–6 threads.

`/usr/bin/footprint --noCategories -p <pid>` reported an 86 MB physical
footprint and a 90 MB peak. That is honest baseline evidence, not a success
against the brief's aspirational 15 MiB investigation target. PRs 06–07 own
the renderer and whole-workload bakeoff that must explain and reduce this bill.
Wakeups, energy, and frame-pacing traces were not collected in this bootstrap
layer.

## Automated regression gates

All commands exited 0:

```text
cd runtime/native-sdk
zig build test -Dwidget-profile=true
zig build test-webview-system-link test-example-macos-widget-windowing

cd ../..
npm test                         # 20/20
npm run typecheck
node cli/bin/weaver.js bundle examples/clock

cd runtime
zig build -Doptimize=ReleaseFast
zig build test
zig build test-platform-services
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
```

The Native SDK profiled suite prints expected failures from negative fixtures
while returning exit code 0. The final Windows cross-build verifies that the
platform split did not remove the existing Win32 implementation.
