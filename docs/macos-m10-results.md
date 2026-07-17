# macOS M10 — production audio provider and Visualizer

Recorded 2026-07-15 on a MacBook Air with Apple M2 (8 cores, 8 GB), macOS
26.5.1 (25F80), arm64, Zig 0.16.0, and Node 23.11.0. The production provider
implementation and steady-state workload are Weaver commit `ba1336b` on
`macos/13-production-audio`.
Raw samples are in [`macos-m10-data.json`](macos-m10-data.json).

## Capability

macOS now projects the existing platform-neutral `audio` provider through one
host-owned public Core Audio process tap. `zig build` produces and ad-hoc signs
`Weaverd.app` as `com.sunkenintime.weaver.host`, with the required usage
description and a 14.2 deployment floor. The CLI launches only that bundled
executable on macOS.

`weaver audio authorize` performs consent work in the foreground using the same
bundle identity. The daemon will not attempt first capture until the marker from
that action is newer than its executable. A rebuild or revocation therefore
returns the provider to an explicit authorization boundary instead of blocking
normal supervision or emitting fake silence.

The Objective-C boundary creates one private, unmuted, global mono tap excluding
the host process, one private aggregate, and one IO proc on a detached worker.
The callback writes a bounded lock-free sample ring. Zig retains the existing
2048-sample FFT, 32 logarithmic bands, AGC, 30 Hz delivery, two-second silence
decay, one final zero, and frame suppression. Default-output changes rebuild the
capture; device failures retry; permission failures park until explicit
reauthorization. The final subscriber destroys capture and analyzer state.

## Automated evidence

| Gate | Result | Evidence |
|---|---:|---|
| Production host and shared analyzer tests | PASS | `cd host && zig build test`; tone-band, frame shape, cadence, silence parking/resume, and capture-loss final-zero tests pass |
| Signed app identity | PASS | `cd host && zig build`; strict deep verification passes and reports ad-hoc `com.sunkenintime.weaver.host` with sealed `Info.plist` |
| Root TypeScript / portable tests | PASS | `npm run typecheck`; `npm test` passes 22/22 |
| Explicit authorization boundary | PASS | isolated daemon reports `authorization-required`, zero starts; injected denial makes `audio authorize` fail without a marker; allow writes the marker and acknowledged reload opens capture |
| One capture / two Visualizers | PASS | two real Visualizer Widget processes report two subscribers, exactly one capture start, live status, provider frames in both logs, and one host-side FFT/frame stream |
| Audible → decay → silence → resume | PASS | injected 440 Hz mono frames activate both Widgets; injected silence decays for two seconds, emits one final zero, then provider and pipe counters remain constant; signal resumes counters |
| Revoke / reauthorize | PASS | injected permission loss reports `permission-revoked`, a nonzero OSStatus, and one final zero; no retry occurs until `audio authorize`, then exactly one new capture starts |
| Device loss / recovery | PASS | injected device loss reports `device-unavailable`, emits one final zero, retries one capture at a time, and returns to `live` after route recovery |
| Teardown and crash regressions | PASS | concurrent uninstall returns provider to idle with zero subscribers and stable counters; the same smoke re-passes daemon/Widget adverse kills, hot swap, backoff, endpoints, and zero-remnant cleanup |

The lifecycle driver is `node cli/test/macos-host-smoke.mjs`. Its injection
exists only in hosts built with `zig build -Dautomation-seam=true` and
activates only when both `WEAVER_AUTOMATION=1` and an explicit
`WEAVER_AUDIO_TEST_CONTROL` file are present; production builds omit the seam
entirely and CI proves its strings are absent from the shipped binary. It crosses the production C ring,
Zig analyzer, UDS fan-out, runtime provider bridge, reconciler, canvas, renderer,
and real AppKit Widget processes; it does not bypass the provider with JSON.

## Whole-application cost

`python3 scripts/macos-audio-cost.py --sample-seconds 10 --output
docs/macos-m10-data.json` sampled the host and every participating Widget once
per second. CPU is summed `ps` percent of one core. Physical footprint is the
de-duplicated aggregate `phys_footprint` reported by `/usr/bin/footprint`; RSS is
also retained because it is not the same metric.

| Workload | Mean CPU | Mean physical footprint | Mean RSS | Audio frames during boundary |
|---|---:|---:|---:|---:|
| Host, audio unsubscribed | 0.17% | 2,458,008 bytes | 8,634,368 bytes | 0 provider / 0 pipe |
| Host + two active Visualizers | 18.06% | 100,723,234 bytes | 260,728,422 bytes | 269 provider / 269 pipe |
| Host + two silent parked Visualizers | 0.87% | 87,548,864 bytes | 194,446,950 bytes | 0 provider / 0 pipe |

The first measurement pass exposed a 100 Hz host poll despite a 30 Hz provider
contract. Moving the host to a 30 ms capture cadence reduced the two-Visualizer
parked result from 2.18% to 0.87% of one core. The active number includes both
isolated runtime processes, two live Metal canvases, the host, injected sample
generation, one FFT/AGC pipeline, serialization, UDS delivery, and rendering.

## Permissioned physical rerun

The original M10 run reached the real authorization boundary but could not
interact with the System Audio Recording prompt. After the user granted the
permission, the final release-closure rerun at Weaver `359be90` and Native SDK
`9cb7cd98` closed the real integrated-output path:

- the signed `com.sunkenintime.weaver.audio-tap-spike` process completed every
  create/start/stop call with OSStatus zero and captured 240,640 real mono
  frames at 48 kHz across 470 callbacks in five seconds;
- playing known system audio produced mean RMS `0.0037366`, peak `0.09918`, a
  first callback at 2459.87 ms, and detected signal 390.68 ms after playback;
- `weaver audio authorize` exited zero for the production
  `com.sunkenintime.weaver.host` identity;
- a real production Visualizer reported one subscriber, one capture start,
  `captureActive: true`, `availability: "live"`, Metal rendering, and provider
  frames that changed from silent to non-silent when the system audio played;
- the extended audible → silence → parked → resume run advanced to 60 frames,
  parked at 94 with a stable counter for 2.5 seconds, then resumed to 120.

That is real callback/mix and production fan-out evidence, not deterministic
injection. The recorded M10 cost table remains the injected repeatable ledger;
the short physical rerun does not replace it with an uncaptured cost claim.

Actual TCC denial/revocation after the grant, protected-stream policy, physical
default-route loss/recovery, Bluetooth, and AirPlay remain `UNVERIFIED`. Only
the integrated output was attached. ScreenCaptureKit, virtual drivers, private
APIs, and fake unavailable frames remain rejected.

Rollback is this Weaver PR only: remove the macOS capture adapter/app bundle and
CLI authorization mode while retaining ADR 0014's explicit unavailable behavior.
The next layer is the public media-provider feasibility and shipping decision.
