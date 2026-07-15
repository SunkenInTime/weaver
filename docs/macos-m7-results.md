# macOS M7 — daemon, IPC, status, and `weaver dev`

Recorded 2026-07-15 on a MacBook Air with Apple M2 (8 cores, 8 GB), macOS
26.5.1 (25F80), arm64, Zig 0.16.0, Node 23.11.0, and Xcode 16.0 (16A242d).
The Weaver branch is `macos/10-macos-daemon`; Native SDK remains pinned to
`359f5c9c` from draft Native PR #5. Runtime and host artifacts were
ReleaseFast. This layer implements [ADR 0013](adr/0013-macos-daemon-uds-process-ownership.md)
without changing Widget source, the public SDK, or `.weave`.

## Runnable capability and non-goals

The macOS CLI now runs `up`, `down`, `status`, install/uninstall reloads, and
the complete `weaver dev` loop through a native `weaverd`. The host owns the
singleton, acknowledged control channel, registry reconciliation, child
process groups, crash/backoff, actual process CPU/footprint/thread samples,
renderer status, and one bounded Unix provider transport per subscribed
Widget. Bundle-only dev edits remain inside the existing runtime and preserve
root hook state; a manifest/window-contract edit deliberately restarts that
one Widget.

PR 10 establishes provider transport but does not fabricate provider values.
CPU/memory collection remains PR 11, the audio decision/implementation remains
PRs 12-13, and media remains PRs 14-15. This layer makes no renderer or overall
performance improvement claim.

## Automated and physical verification

| Command | Exit | Result/evidence |
|---|---:|---|
| `cd host && zig build test && zig build -Doptimize=ReleaseFast` | 0 | macOS adapter, portable supervisor, path-cap, and host build pass |
| `cd runtime && zig build test && zig build -Doptimize=ReleaseFast` | 0 | runtime suite plus real Unix line framing and bounded-queue transport pass |
| `npm run typecheck && npm test` | 0 | SDK/CLI types and root unit suite pass |
| `node cli/test/install-smoke.mjs` | 0 | deterministic artifact/install/replace/uninstall lifecycle passes with acknowledged macOS reloads |
| `node cli/test/macos-host-smoke.mjs` | 0 | dev hot swap/restart, concurrent mutations, provider endpoint, host/Widget crash orders, backoff/recovery, and cleanup pass |

The physical Conjure run started host PID 20702 and Clock PID 20747. Changing
only a rendered class produced `dev hot swap applied (preserved root hook
state)` while PID 20747 remained live. Changing size `[240, 110]` to
`[241, 110]` produced `weaver dev restarted widget: window config changed`
and PID 28062. Ctrl-C removed the dev registration; the acknowledged status
contained zero Widgets before `down` stopped the host.

An installed Clock later reported host PID 44891, Widget PID 44913,
`backend: "gpu"`, 47.78 MiB sampled physical footprint, 0.15% of one core,
and eight threads. These are a single functional status sample, not a stable
performance measurement. The actual Metal frame transition writes `gpu` to
status; software demotion/recovery writes `software`/`gpu` rather than leaving
the renderer as unknown.

The adverse-order run killed host PID 46964 while Widget PID 46971 was still
alive. Starting the replacement host yielded host PID 46995 and Widget PID
46997, and validated marker cleanup proved PID 46971 was gone. Killing the
Widget twice yielded PID 47114 after the one-second recovery, an observable
`backoff` state on the second failure, then running PID 47696 after the
five-second delay. The automated smoke repeats these assertions rather than
depending on the recorded PIDs.

Two separate CLI processes installed Alpha and Beta concurrently; the atomic
registry contained both and status reconciled both. Two concurrent uninstalls
then produced an empty registry/status. Installing the provider-subscribed
System fixture created a 32-hex-token per-Widget socket below the short
mode-0700 runtime root, connected successfully, and removed the endpoint on
uninstall. The runtime transport unit test verifies newline framing, an 8 KiB
frame bound, and drop-oldest behavior at its four-entry queue bound.

## Risks, rollback, and remaining physical boundary

- A SIGKILLed host necessarily leaves a Widget alive until the replacement
  host starts; the new host validates both its private marker and the live
  `proc_pidpath` before killing it. Normal `down` remains synchronous and
  leaves no such interval.
- Provider endpoint authentication is possession of an unguessable path under
  a user-only directory, delivered only in the child environment. There is no
  public SDK-visible endpoint or cross-user socket.
- Intel execution is delegated to the `macos-15-intel` CI leg; there is no
  physical Intel Mac in this run. The layer makes no Intel performance claim.
- No new visible-window semantic is introduced, so PR02/PR04's ScreenCaptureKit,
  external-display, Stage Manager, Show Desktop, and sleep/wake blockers remain
  unchanged. The dev smoke correlates runtime logs and status; it does not
  claim a new screen recording.
- PR 10 is independently rolled back by reverting the macOS adapter/CLI branch;
  the portable PR09 supervisor and Windows adapter remain its parent boundary.

## Cleanup

All dev, installed, provider-subscribed, deliberately crashed, and recovered
Widget processes were terminated. The daemon was stopped, all control/provider
sockets and singleton files were removed, the isolated HOME roots and registry
content were deleted, and no desktop setting was changed.
