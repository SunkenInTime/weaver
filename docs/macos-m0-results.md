# macOS M0 results: baseline and build seams

PR 01 establishes the support contract and the first compile-time platform
boundary without claiming that `weaver-widget`, `weaverd`, or the renderer run
on macOS yet. Windows remains the production surface at this layer.

## Support matrix

| Target | Contract at M0 | Physical evidence |
|---|---|---|
| Apple silicon | Primary execution and performance target. TypeScript and the Native SDK stock/widget profiles are required in CI. | Apple M2 MacBook Air, 8 GB, macOS 26.5.1 (25F80). |
| Intel macOS | Must compile and run the same automated M0 suites on the `macos-15-intel` GitHub runner. Performance and desktop-manager behavior remain unverified until physical Intel hardware is available. | CI only. |
| Windows x86_64 | Existing behavior and required CI remain unchanged. | The pre-Lane-D Windows evidence remains in the existing milestone documents. |

The provisional developer-build floor is macOS 13.0 because Zig 0.16.0's
documented host support starts there. This is not the final product floor: the
public audio-capture decision in PR 12 owns the final minimum macOS version.
Weaver does not yet promise signing, notarization, universal artifacts,
login-item installation, or a public macOS installer.

## Toolchain bootstrap

- Node.js 22 or newer; CI uses Node 22.
- Zig 0.16.0 exactly. On Apple silicon, the official archive is
  `zig-aarch64-macos-0.16.0.tar.xz`; Intel uses
  `zig-x86_64-macos-0.16.0.tar.xz`.
- Xcode command-line build support with the macOS SDK. The physical M0 run
  used Xcode 16.0 (16A242d) and the macOS 15.0 SDK.

The local physical run installed the official Zig archive under
`~/.local/opt/zig-aarch64-macos-0.16.0` and exposed it through
`~/.local/bin/zig`. CI downloads the same version into `RUNNER_TEMP`.

## Path contract

| Purpose | Windows | macOS |
|---|---|---|
| Persistent Weaver data | `%LOCALAPPDATA%\weaver` | `~/Library/Application Support/Weaver` |
| Logs | `%LOCALAPPDATA%\weaver\logs` | `~/Library/Logs/Weaver` |
| Ephemeral control/provider IPC | Named objects and pipes scoped to the current user | A short per-user directory derived from `TMPDIR`, mode `0700`, containing host-created unguessable Unix-domain endpoint names |

macOS sockets never live below Application Support. The host owns endpoint
creation and stale-entry cleanup; a child learns its unguessable endpoint only
through its environment. Exact line/frame bounds stay identical to Windows.

## Build seams added

- `runtime/build.zig` now chooses QuickJS flags and system linkage from the
  compile target. Windows keeps its existing defines, monitor bridge, and
  WinHTTP linkage; macOS receives neither Windows source nor Windows library.
- `runtime/src/platform/root.zig` selects one implementation at compile time.
  Process identity is the first consumer: Win32 still calls
  `GetCurrentProcessId`, while macOS uses public POSIX `getpid`.
- `zig build test-platform-services` is a small target that proves the chosen
  platform implementation without pretending the full runtime already ports.
- The CLI import wall compares esbuild paths against a canonical source root.
  This preserves containment while accepting macOS's `/var` to `/private/var`
  canonical path for legitimate nested widget modules.
- macOS CI covers Apple silicon and Intel with Node/type tests, the runtime
  platform seam, and Native SDK stock plus Weaver widget-capacity profiles.

## Physical M0 commands and raw results

Machine: Apple M2 MacBook Air, 8 GB; macOS 26.5.1 build 25F80; arm64; Xcode
16.0; macOS 15.0 SDK; Zig 0.16.0; Node 23.11.0 for the local run.

| Command | Result |
|---|---|
| `npm ci` | PASS; 0 vulnerabilities |
| `npm run build && npm test && npm run typecheck` | PASS; 20/20 Node tests |
| `zig build test-platform-services` in `runtime` | PASS |
| `zig build test` in `runtime/native-sdk` | PASS |
| `zig build test -Dwidget-profile=true` in `runtime/native-sdk` | PASS |
| `zig build -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off` in `runtime` | Expected M0 stop: 9 compile errors from the enumerated Win32 modules below |

The Native SDK suites intentionally print diagnostics from negative fixtures
(invalid markup, package mismatches, truncated fonts, and replay divergence);
both commands exited 0.

## Enumerated blockers after M0

The macOS runtime build now passes Native SDK AppKit selection, QuickJS C
compilation, and target-specific linkage. It stops at these known source
boundaries:

- `runtime/src/manifest.zig` imports `windows_monitor.h` for screen geometry;
- `runtime/src/provider.zig` imports `windows.h` for named-pipe transport;
- `runtime/src/widget_log.zig` imports `windows.h` for file sizing/rotation.

The remaining known Windows dependencies are deliberately assigned to later
layers: `js_engine.zig` monotonic deadlines, `storage.zig` data roots,
`network.zig` WinHTTP, and the host/renderer executables. PR 03 owns runtime
services/logging/storage/provider inertness, PR 04 owns display geometry, PR 05
owns HTTPS, PR 09 owns supervisor extraction, and PR 10 owns the macOS host.

## Evidence and performance claim

M0 is headless and makes no runtime performance claim. No computer-use gate is
required because no visible macOS widget behavior is claimed. The first
visible evidence is PR 02's Native SDK window harness and PR 03's direct Clock.
