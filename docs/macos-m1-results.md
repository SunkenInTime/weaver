# macOS M1 results: AppKit widget-window projection

PR 02 makes the Native SDK's existing `ShellWindow` widget contract real on
the system AppKit backend. Weaver's own macOS Widget executable is still a PR
03 concern; this layer proves the window and compositor edge it will use.

## Claim and non-goals

The Native SDK now forwards `transparent`, `layer`, `click_through`, and
`no_activate` for startup and secondary windows. Explicit widget windows use
transparent AppKit surfaces, premultiplied Metal canvas presentation,
nonactivating panels, pointer pass-through, desktop/normal/floating levels,
and widget collection behavior. Windows with the four default values retain
the ordinary `NSWindow`, regular-application, key-and-activate path.

This layer does not yet claim display anchoring, coordinate conversion,
Mission Control/Stage Manager survival, or the final empirically tuned
desktop policy. Those remain PR 04 gates. The Chromium/CEF host accepts the
expanded ABI for compatibility but PR 02's implementation and harness target
the system AppKit/WebKit host.

## Build identity

- Weaver branch: `macos/02-appkit-windowing` (pointer commit follows the Native SDK PR)
- Native SDK branch and commit: `macos/01-appkit-windowing`, `819e878a`
- Native SDK draft PR: [SunkenInTime/native#1](https://github.com/SunkenInTime/native/pull/1)
- macOS: 26.5.1 (25F80), Apple M2 MacBook Air, arm64, 8 cores, 8 GB
- Display: one built-in display, 1710x1112 logical points, 2x backing scale;
  visible frame 1710x1073
- Toolchain: Zig 0.16.0, Xcode 16.0 (16A242d), macOS 15.0 SDK
- Relevant permission: screen/window recording permission unavailable to the
  unattended tool process
- Evidence processes: T3 Code PID 55617; final policy-matrix harness PID 10946

## Policy projection

| Shell contract | AppKit projection |
|---|---|
| default fields | existing plain `NSWindow`, regular activation, normal level, default collection behavior |
| `transparent` | `opaque = NO`, clear allocation-time background, no system shadow; canvas declares premultiplied alpha |
| `chromeless` | borderless window/panel with key/main capability retained |
| `layer = bottom` | `CGWindowLevelForKey(kCGDesktopIconWindowLevelKey) - 1` |
| `layer = normal` | `NSNormalWindowLevel` |
| `layer = topmost` | `NSFloatingWindowLevel` |
| `click_through` | `ignoresMouseEvents = YES` |
| `no_activate` | accessory process plus `NSPanel`/`NSWindowStyleMaskNonactivatingPanel`; show paths never call `NSApp activate` |
| widget collection | all Spaces, stationary, ignored by normal cycling, fullscreen auxiliary |

Unbundled AppKit startup can transiently activate even an accessory process.
The host therefore identifies the previously visible regular application from
the public front-to-back Core Graphics window list and returns activation on
the first run-loop turn. This was added after the first physical run exposed
focus theft.

## Automated verification

| Command | Exit | Result/evidence |
|---|---:|---|
| `zig build test` | 0 | PASS, stock profile; expected negative-fixture diagnostics printed |
| `zig build test -Dwidget-profile=true` | 0 | PASS, Weaver capacity profile; expected negative-fixture diagnostics printed |
| `zig build test-webview-system-link test-example-macos-widget-windowing` | 0 | PASS, Objective-C system host and new harness compile/test |
| managed `native build -Dplatform=macos -Dweb-engine=system -Doptimize=Debug` in the harness | 0 | PASS, produced `zig-out/bin/macos-widget-windowing` |
| `git diff --check` | 0 | PASS |

One deliberately parallel attempt at the stock and widget-profile suites
failed because both commands mutate the same `.zig-cache/test-*` fixture
paths. Both supported serial invocations above then passed; no concurrent
suite result is used as evidence.

## Physical and machine-readable verification

The fixture at `runtime/native-sdk/examples/macos-widget-windowing` declares
six transparent, chromeless, nonactivating 280x160 windows: three layers by
interactive/pass-through input mode. Every window hosts a premultiplied Metal
`gpu_surface`.

With `NATIVE_SDK_WINDOW_POLICY=1`, the AppKit host and an independent Core
Graphics inventory agreed:

| Window ids | Contract | Resolved level | CG on-screen count | Focus result |
|---|---|---:|---:|---|
| 1-2 | bottom, interactive/pass-through | -2147483604 | 2 | no activation retained |
| 3-4 | normal, interactive/pass-through | 0 | 2 | no activation retained |
| 5-6 | topmost, interactive/pass-through | 3 | 2 | no activation retained |

The same machine reported desktop `-2147483623`, desktop icons
`-2147483603`, normal `0`, and floating `3`. The selected bottom level is
therefore above the wallpaper, one level below Finder desktop icons, and well
below ordinary applications. Core Graphics reported all six declared bounds
on screen. Host events showed `activate` immediately followed by `deactivate`;
an independent `NSWorkspace` query then reported `T3 Code (Nightly)` still
frontmost.

The stock `gpu-surface` example reported
`transparent=0 layer=0 appkit_level=0 click_through=0 no_activate=0
activation_policy=0 collection_behavior=0` and became the ordinary frontmost
application, proving the default path did not acquire widget policy.

### Required recording status

`UNVERIFIED`: no computer-use recording could be attached. Chronicle was not
running. `screencapture` returned `could not create image from display`.
ScreenCaptureKit returned `SCStreamErrorDomain Code=-3801` with `The user
declined TCCs for application, window, display capture`. The run does not
substitute machine-readable window inventory for a visual claim; the exact
fixture, policy logs, levels, bounds, activation events, and focus query are
recorded so a permissioned rerun can add the missing artifact without code
changes.

## Whole-application cost ledger

PR 02 makes no performance or energy claim. CPU, memory, wakeups, and frame
latency were not sampled, so none are reported. PR 06 owns the renderer
bakeoff and whole-system cost accounting.

## Failures, risks, and rollback

- The first physical harness run stole focus because entering `NSApp run`
  transiently activates an accessory process. The public Core Graphics /
  `NSRunningApplication` hand-back path corrected it; the final run emitted a
  deactivate event and left T3 Code frontmost.
- The bottom policy is justified by measured levels on this machine, but Show
  Desktop, Mission Control, Stage Manager, Space switching, sleep/wake, and
  reconnect remain PR 04 physical gates.
- Visual recording remains `UNVERIFIED` because of TCC, as detailed above.
- Revert Native SDK fork PR 01 plus the Weaver pointer PR to roll back this
  layer independently.

## Cleanup

- Harness and stock-example processes terminated: yes
- Sockets/endpoints created: none
- Temporary registrations/data: normal Native SDK dev state only; no system
  registration or settings mutation
- Reversible desktop settings restored: unchanged
- Native SDK branch pushed and clean: yes
