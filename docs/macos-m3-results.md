# macOS M3 — primary-display anchors and desktop policy

Recorded 2026-07-15 on a MacBook Air with Apple M2 (8 cores, 8 GB), macOS
26.5.1 (25F80), arm64, Zig 0.16.0, and Node 23.11.0.

## Claim

The Native SDK now has one cross-platform primary-display anchor contract in
logical points. The AppKit system-engine host resolves top-left, top-right,
bottom-left, and bottom-right against the primary display's current visible
frame and reapplies the contract after display-topology, active-Space, and wake
notifications. Weaver maps its existing portable manifest anchor into that
contract; it does not add a monitor selector or a macOS-only manifest field.

This layer is published as stacked draft
[Native SDK PR #3](https://github.com/SunkenInTime/native/pull/3) plus the
matching [Weaver PR #6](https://github.com/SunkenInTime/weaver/pull/6).
Physical placement on the attached Retina display passes.
The full multi-display and desktop-management gate remains **UNVERIFIED** where
this machine lacks hardware, enabled modes, or capture permission.

## Coordinate and topology contract

- `NSScreen.screens.firstObject` is the OS-declared primary display. Every
  screen is enumerated when topology changes, but Widget manifests continue to
  target only `primary`.
- AppKit bottom-left global rectangles cross one explicit boundary into Native
  SDK top-left logical points. Renderer pixels are not involved in placement.
- Anchors use the visible frame, so the menu bar and Dock are excluded by the
  OS before corner math runs.
- Window size and offsets remain logical points at Retina and scaled modes.
- The pure resolver preserves signed visible-frame origins. Tests cover a
  synthetic `(-1728, -900, 1512 x 860)` visible frame and all four corners.
- Anchored windows observe screen-parameter, active-Space, and workspace-wake
  notifications. A no-op reapply neither resets the frame nor emits a duplicate
  window-frame event.
- The optional Chromium macOS host rejects anchors explicitly. Silently
  ignoring a placement contract would be worse than an honest unsupported
  backend; Weaver uses the AppKit system engine for this surface.

## Retina physical anchor matrix

The integrated display reported a full logical frame of `1710 x 1112`, a
visible top-left frame of `(0, 39, 1710 x 1073)`, and a backing scale of `2.0`.
The production Clock is `240 x 110` with a 24-point offset on each axis.

| Corner | Expected top-left frame | CGWindow frame | Result |
|---|---:|---:|---|
| top-left | `(24, 63, 240 x 110)` | `(24, 63, 240 x 110)` | PASS |
| top-right | `(1446, 63, 240 x 110)` | `(1446, 63, 240 x 110)` | PASS |
| bottom-left | `(24, 978, 240 x 110)` | `(24, 978, 240 x 110)` | PASS |
| bottom-right | `(1446, 978, 240 x 110)` | `(1446, 978, 240 x 110)` | PASS |

The final direct top-right run reported one on-screen `weaver-widget` window
at `(1446, 63, 240 x 110)`, layer `-2147483604` (desktop-icon-minus-one). The
host's display-policy trace reported the same frame, scale, primary identity,
and anchor inputs.

## Desktop-management matrix

| Behavior | Result | Correlated evidence or exact blocker |
|---|---|---|
| Retina 2x placement | PASS | Four exact logical-point/CGWindow matches above |
| Scaled mode | UNVERIFIED | No reversible alternate display mode was already configured; this unattended run did not alter the user's display settings |
| Secondary on every side / negative origins | UNVERIFIED | Only the integrated display is attached; signed-origin math passes deterministic tests, but there is no physical secondary display |
| Display disconnect/reconnect | UNVERIFIED | The only attached display is integrated and cannot be disconnected |
| Mission Control | PASS (trigger) | Launching Mission Control left the Clock on-screen at the same frame/layer and left T3 Code frontmost |
| Show Desktop | UNVERIFIED | Synthetic key invocation blocked on Accessibility/Automation permission; no permission or setting was changed |
| Stage Manager | UNVERIFIED | `com.apple.WindowManager GloballyEnabled=0`; the run did not change the user's desktop mode |
| Space switching | UNVERIFIED | No independent Space was safely available to the unattended harness; the host observes the public active-Space notification |
| Sleep/wake | UNVERIFIED | An unattended `sleepnow` gate cannot guarantee a wake path; the host observes `NSWorkspaceDidWakeNotification` |
| Focus / Dock presence | PASS | Accessory activation policy (`1`), Widget inactive, T3 Code frontmost; no Dock tile and no focus theft |

The Mission Control result proves that the physical trigger did not disturb the
window. It does not substitute for the unrecorded Show Desktop, Stage Manager,
Space, sleep, or topology transitions.

## Capture limitation

The required computer-use recording could not be produced. Chronicle was not
running, ScreenCaptureKit previously returned TCC error `-3801` (`The user
declined TCCs for application, window, display capture`), and the direct
fallback command failed with:

```text
could not create image from display
```

No screenshot is attached to this result rather than substituting a synthetic
image for physical placement evidence. `NSScreen`, host policy logs, and
`CGWindowListCopyWindowInfo` provide the correlated numeric evidence above.

## Cost ledger

The anchor layer adds three notification observers only while at least one
anchored window exists. It adds no worker, timer, renderer, or process. During
the same 1 Hz Clock workload, five one-second `top` samples were `0.0, 0.6,
0.6, 1.2, 1.1` percent of one core: mean `0.70%`. The process held six threads.

`/usr/bin/footprint --noCategories -p <pid>` reported 91 MB physical and 91 MB
peak. This is 5 MB above M2's 86 MB physical snapshot but within a different
short run; it is not attributed to the observers without an Instruments
allocation comparison. PRs 06–07 still own the whole-system renderer and
memory investigation. Wakeups and energy were not captured in this layer.

## Automated regression gates

All available commands exited 0:

```text
cd runtime/native-sdk
scripts/gate.sh fast
zig build test -Dwidget-profile=true
zig build test-webview-system-link test-example-macos-widget-windowing test-desktop-platform

cd ../..
npm test
npm run typecheck

cd runtime
zig build test
zig build test-platform-services
zig build -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
```

The fast Native SDK gate completed in 194 seconds. Its optional Chromium-host
link check was skipped because the CEF SDK layout is not installed. An explicit
Chromium link attempt failed with the actionable dependency message:

```text
missing CEF dependency for -Dweb-engine=chromium
native cef install --dir ../../third_party/cef/macos
```

The AppKit system-engine link and physical Widget path are covered; Chromium's
new rejection branch remains source-reviewed but not locally linked.
