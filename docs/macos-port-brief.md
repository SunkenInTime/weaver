# macOS implementation plan (Lane D)

This is the implementation plan for bringing Weaver to macOS at parity with
the current Windows v0 surface. It is written for the agent sessions doing the
work on Mac hardware. Read `README.md`, `CONTEXT.md`, `sdk/CONTRACT.md`, every
ADR (especially 0002, 0006, 0007, 0008, 0010, and 0011), `docs/ROADMAP.md`,
`docs/fork-consolidation.md`, and the most recent milestone result documents
before changing code.

The port is complete when the same widget source can be checked, packed,
installed, supervised, rendered, hot-swapped, measured, and uninstalled on
macOS without an OS-specific concept entering the widget-facing SDK. This plan
covers parity with the product that exists when Lane D starts. It does not pull
future manager, gallery, remix, or general packaging work forward merely
because macOS is being added.

## Non-negotiable delivery shape: stacked PRs

The macOS implementation MUST be delivered as stacked pull requests. Do not
put the port in one long-lived branch and do not wait until the end to expose a
giant review. Every PR in the stack must establish one reviewable capability,
carry its own tests and evidence, and leave its branch internally coherent.

There are two repositories and therefore two coordinated stacks:

1. **Native SDK fork stack** in `SunkenInTime/native`, based on the canonical
   `weaver-main` branch. These PRs own AppKit/Metal behavior that projects an
   existing internal platform contract. They are Weaver product work and are
   not presumed to be upstream contributions.
2. **Weaver stack** in this repository, based on `master`. These PRs own the
   runtime, CLI, daemon, providers, tests, CI, and the submodule pointers to the
   corresponding fork commits.

Use numbered branches such as `macos/01-build-seams`,
`macos/02-appkit-windowing`, and `macos/03-runtime-clock`. PR 02 targets PR
01's branch, PR 03 targets PR 02's branch, and so on. The PR description must
say `Stack: 03/N`, link its immediate parent, state what becomes runnable at
that layer, and list what is deliberately still missing. Review diffs against
the parent PR, never against `master` while the stack is open.

When a Weaver PR depends on a fork PR, pin the submodule to the exact reviewed
fork commit and link the fork PR. Merge the fork stack bottom-up first. Update
submodule pointers if merge hashes change, rerun the affected Weaver gates,
then merge the Weaver stack bottom-up. Never merge a middle PR while a lower
PR is unresolved. Never extend the frozen historical fork branches
(`weaver-fork`, `weaver-fork-m3`, `weaver-fork-gpu`,
`weaver-fork-renderer`, or `weaver-fork-hybrid`).

If a PR reveals that its parent abstraction is wrong, fix the lowest affected
PR and restack the descendants. Do not conceal foundational corrections in a
later PR. No pushes or PR creation happen without the normal human review
checkpoint.

Every PR description in either stack must include:

- its parent PR and exact base branch;
- the capability added at this layer and explicit non-goals;
- the fork commit/submodule pointer when applicable;
- automated commands and results on macOS and Windows;
- manual evidence required by the layer;
- measured performance or a statement that the PR makes no performance claim;
- known risks, rollback boundary, and the next PR in the stack.

## Product and platform invariants

- Widget source and the public SDK contract remain identical across Windows
  and macOS. No `macos`, `AppKit`, `Metal`, `NSWindow`, screen-coordinate, or
  permission-system term may enter `@weaver/sdk` or `.weave`.
- One Widget remains one crash-isolated runtime process. The host remains the
  only owner of shared providers and supervision.
- The portable `.weave` source, declared surface, lineage, install-owned copy,
  and import boundary remain authoritative on both platforms.
- Quiet widgets must be honestly quiet. Timers, polling, provider transport,
  and presentation may not leave unexplained idle CPU.
- All platform differences live behind small internal seams. Avoid a growing
  collection of `if (builtin.os.tag == ...)` checks in product logic.
- Unsupported behavior must fail explicitly or report unavailable. A macOS
  stub must never claim that a provider, renderer, or permission is working.
- Preserve stock Native SDK behavior. Widget-specific AppKit behavior must be
  selected by the existing window/profile declarations and must not turn every
  Native SDK app into a desktop accessory.
- Every measured claim goes in `docs/macos-mN-results.md` with the hardware,
  macOS build, architecture, Zig version, command, metric definition, and raw
  result. Windows and macOS memory metrics must not be compared as if they were
  the same measurement.

## Target support contract

PR 01 must record the initial support matrix before code depends on it:

- Apple silicon is the first execution and performance target.
- Intel macOS must at least compile and run automated tests until physical
  Intel verification is available. If it cannot be supported, that is an
  explicit product decision, not an accidental build failure.
- PR 01 records a provisional minimum macOS version. The audio-provider spike
  chooses the final floor because capture APIs, permissions, and entitlements
  are the strongest constraint. Windowing or renderer convenience must not
  silently raise it first.
- Developer builds are the initial distribution surface. Signing,
  notarization, universal artifacts, login-item installation, and a public
  installer stay in the later packaging roadmap unless a port feature truly
  cannot be tested without a signed bundle.

## Architecture to establish

### Platform services

Create an internal platform-services boundary rather than cloning whole
modules. The runtime and CLI need the same documented path contract even
though one implementation is Zig and the other TypeScript:

- Windows data: `%LOCALAPPDATA%\weaver`
- macOS data: `~/Library/Application Support/Weaver`
- macOS logs: `~/Library/Logs/Weaver`
- Ephemeral IPC: a per-user, permission-restricted short path derived from
  `TMPDIR`; never place a long Unix socket path under Application Support.

The runtime boundary owns data/log paths, process identity, monotonic time,
screen geometry, logging, network transport, and provider transport. The host
boundary owns singleton acquisition, control signalling, child-process
lifecycle, process metrics, provider endpoints, and graceful termination.
Cross-platform supervisor, registry, backoff, status serialization, renderer
policy, JSON protocol, and provider fan-out stay platform-neutral.

Unix-domain endpoints must be user-only, remove stale filesystem entries
safely, authenticate through host-created unguessable endpoint names passed in
the child environment, bound line/frame sizes exactly like Windows, and close
cleanly enough that a crashed host can restart without manual cleanup.

### macOS window semantics

The existing `ShellWindow` fields are the contract. AppKit must project them:

- `transparent`: `opaque = NO`, clear window background, premultiplied canvas
  presentation, and no first-frame white/black flash.
- `chromeless`: borderless widget window without standard chrome.
- `layer = bottom`: the empirically verified desktop layer. Do not assume one
  Core Graphics level is correct merely because its name contains `Desktop`.
- `layer = topmost`: the macOS analogue of an always-on-top widget without
  breaking fullscreen or Spaces policy.
- `click_through`: `ignoresMouseEvents`, dynamically correct if the window is
  ever reconfigured.
- `no_activate`: no focus theft, no application activation, no Dock or
  Command-Tab presence for widget-only processes, while interactive widgets
  retain the input they contractually support.
- Desktop behavior: stationary placement, intended all-Spaces behavior,
  exclusion from normal window cycling, and explicit verification under Show
  Desktop, Mission Control, Stage Manager, Space switching, screen sleep/wake,
  and display reconnect.

AppKit screen frames use a different origin convention from Weaver's
top-left logical coordinates. Convert once at the platform edge. Anchor
against `NSScreen.visibleFrame` in logical points, keep the chosen display's
origin intact, and test displays above, below, left, and right of the primary
display. Do not reproduce the Windows physical-pixel/DPI conversion on macOS;
Retina backing scale and logical placement are different contracts.

### Rendering policy

The macOS port does not automatically inherit the Windows shared renderer.
That process exists because measurements justified sharing D3D11 and
DirectComposition resources. Start with the already available damage-aware
software path for the baseline Clock, then map a Widget requesting `gpu` to
Native SDK's in-process Metal presenter. Measure both.

The initial policy is:

- quiet/static Widgets default to software;
- Widgets selected as GPU Widgets use Metal;
- `weaver-renderer` remains Windows-only;
- a shared Metal renderer is a later architectural change only if measured
  aggregate footprint, startup cost, or reliability proves that it pays rent.

Backend reports, status output, demotion, recovery, frame cadence, damage,
alpha, images, text, input hit-testing, and canvas clocks must remain honest.
A requested but unavailable Metal backend must demote visibly to software or
fail explicitly; it may not report `metal` while presenting software pixels.

### Host and provider policy

Port the supervisor by extracting reusable behavior from the Win32 daemon,
not by copying `host/src/main.zig` into a second daemon. The macOS host needs:

- per-user singleton ownership and acknowledged reload/down commands;
- widget spawn, graceful shutdown, forced termination, crash detection, and
  the existing backoff semantics;
- atomic registry/status handling and install-owned source semantics;
- per-widget provider endpoints and subscription-driven provider lifetime;
- process PID, thread count, CPU, and a documented macOS footprint metric;
- software/Metal status without launching the Windows renderer process;
- shutdown and restart cleanup that leaves no child or socket behind.

CPU and memory providers are public-system-API work. Audio and system-wide
media are research gates because API availability, privacy prompts,
entitlements, sandboxing, signing, and distribution rules can change what is
honestly shippable. The research PRs must choose a public, distributable path
or explicitly narrow the supported surface. Private framework use is not a
casual implementation detail and requires a loud product decision.

## The stacked implementation PRs

The sequence below is mandatory unless a newly discovered dependency is
documented and approved. A PR may be split into smaller stacked PRs; adjacent
PRs must not be collapsed if that destroys an independently reviewable gate.

### PR 01 — Baseline, support matrix, and build seams

**Repository:** Weaver.

Make the existing Windows assumptions visible and introduce compile-time
platform module selection without changing Windows behavior. Record the
support matrix, toolchain bootstrap, macOS commands, data/IPC path contracts,
and result-document template. Make QuickJS C flags and system-library linkage
target-specific. Add a macOS CI job for TypeScript tests and every Zig target
that can honestly compile at this layer; expected missing runtime pieces must
be listed in the PR rather than hidden by broad CI exclusions.

**Gate:** Windows CI remains green; Node tests pass on macOS; Native SDK stock
and widget-profile test commands are known; `zig build` reaches only the
enumerated platform blockers. Result: `docs/macos-m0-results.md` begins.

### PR 02 — AppKit widget-window projection

**Repositories:** Native SDK fork PR 01, then a Weaver pointer PR stacked on
Weaver PR 01.

Thread `transparent`, `layer`, `click_through`, and `no_activate` through the
macOS Zig/Objective-C boundary for startup and secondary windows. Implement
widget-only activation policy, transparent first presentation, bottom/normal/
topmost levels, pointer pass-through, nonactivation, and collection behavior.
Keep ordinary Native SDK AppKit windows byte-for-byte equivalent in behavior
where the fields retain defaults. Add platform tests around option forwarding
and any testable pure policy conversion.

**Gate:** a small Native SDK harness shows one transparent chromeless window
with each layer/input combination; stock Native SDK macOS examples still act
like normal applications; manual behavior matrix is attached.

### PR 03 — Portable runtime and direct software Clock

**Repository:** Weaver, stacked on PR 02.

Make `weaver-widget` compile and run on macOS. Replace Win32-only PID and turn
deadline calls with the internal platform service; make logging and rotation
portable; use the macOS data/log roots; make provider transport inert only
when no endpoint is supplied; isolate the Windows monitor bridge; and map the
software backend honestly. Keep URL parsing and origin policy platform-neutral
even if the network transport lands in PR 05. `weaver dev` is not claimed yet;
the direct runtime command is the deliberate bootstrap harness.

**Gate:** after `weaver bundle examples/clock`, direct invocation of the
runtime displays Clock in software mode; storage survives restart; logs rotate;
the runtime exits cleanly; idle CPU and footprint are recorded. No daemon is
required for this gate.

### PR 04 — Displays, anchoring, Spaces, and desktop survival

**Repositories:** Native SDK fork PR 02 if host support is needed, plus the
corresponding Weaver PR.

Implement primary-display visible-frame discovery and the full top-left/
top-right/bottom-left/bottom-right anchor contract in logical points. Cover
negative primary-screen origins caused by multi-display arrangements and
enumerate secondary screens for desktop-change handling without adding a new
monitor selector to the SDK. Reapply or preserve placement through display
changes without inventing a macOS-only widget setting. Finish the
empirical AppKit layer/collection policy from PR 02 based on physical tests.

**Gate:** anchor screenshots and logged frames on Retina and scaled modes;
multi-display arrangements on every side of the primary; Show Desktop,
Mission Control, Stage Manager, Space switching, sleep/wake, and display
disconnect/reconnect matrix. No focus theft or Dock tile.

### PR 05 — Network fetch parity

**Repository:** Weaver.

Implement the macOS HTTPS transport behind the existing request/result
contract. Preserve exact declared-host checks, HTTPS-only policy, redirect
denial across origins, request/response size caps, timeout semantics, headers,
GET/POST behavior, worker isolation, and QuickJS turn safety. Prefer a public
system or Zig transport whose trust-store and cancellation behavior can be
tested; do not shell out to `curl`.

**Gate:** the existing policy tests plus local deterministic HTTPS tests cover
success, timeout, oversized body, disallowed redirect, malformed URL,
certificate failure, and shutdown with an active request. Windows WinHTTP
regressions remain green.

### PR 06 — Software/Metal rendering parity

**Repositories:** Native SDK fork PR 03 only if presenter fixes are required,
plus Weaver.

Map `renderBackend: "gpu"` to Metal on macOS while retaining software for quiet
Widgets. Verify premultiplied alpha, transparent clears, text, images, canvas,
damage, input geometry, first-frame show, occlusion pacing, and frame clocks.
Implement honest fallback/demotion reporting. Do not add a shared Metal
renderer in this PR.

**Gate:** Clock and Pomodoro in software; Visualizer and the synthetic parity
fixture in Metal; pixel comparisons where deterministic; 10-minute cadence
and idle captures; repeated GPU Widget launch/close with no monotonic resource
growth; backend shown correctly in logs.

### PR 07 — Cross-platform CLI and artifact lifecycle

**Repository:** Weaver.

Finish platform-aware executable discovery and data/log paths. Make
`init`, `check`, `bundle`, `pack`, archive inspection, `install`, `uninstall`,
and `logs` work on macOS while preserving deterministic `.weave` bytes and the
install-owned copy boundary. Port the PowerShell-only install smoke to a
cross-platform driver or add an equivalent macOS test without weakening the
Windows smoke. Do not add a second artifact format or platform-specific source
manifest.

**Gate:** pack on Windows and macOS produces identical bytes from identical
source; cross-platform pack/open/install round trips; traversal, symlink,
containment, replacement, rollback, abandoned-lock, and cleanup tests pass.
Host-dependent commands remain clearly unavailable until PR 09.

### PR 08 — Extract the portable supervisor core

**Repository:** Weaver.

Refactor `weaverd` so registry reconciliation, widget slots, backoff, desired
state, status serialization, provider subscription bookkeeping, and renderer
selection are platform-neutral. Put current named events, named pipes,
process handles, Job/Win32 termination, and process counters behind a Windows
host adapter. This PR is intentionally a Windows behavior-preservation PR;
do not mix the macOS daemon into the extraction.

**Gate:** all current Windows host tests, install smoke, hot-swap, provider,
renderer recovery, crash/backoff, status, and shutdown gates remain green.
Unit tests exercise the extracted supervisor with a fake platform adapter.

### PR 09 — macOS daemon, IPC, status, and `weaver dev`

**Repository:** Weaver.

Implement the macOS host adapter: singleton/control channel, acknowledged
reload, Unix-domain provider endpoints, child spawn/environment, graceful and
forced termination, crash observation, stale endpoint cleanup, process CPU/
thread/footprint metrics, and no external renderer process. Wire CLI
`up`, `down`, `status`, `logs`, install reload, uninstall reload, and
`weaver dev` to it. Preserve stateful in-process hot-swap when only the bundle
changes and restart only when the manifest/window contract changes.

**Gate:** the complete Conjure loop works: init → dev → edit → state-preserving
hot-swap → stop. Install/replace/uninstall is acknowledged and leaves no
process or endpoint behind. Kill the host and Widgets in adverse orders and
verify recovery/backoff/status. Run concurrent CLI registry mutations.

### PR 10 — CPU and memory providers

**Repository:** Weaver.

Implement host-owned macOS CPU and memory collection through public system
APIs. Keep collection subscription-driven, emit the existing provider JSON
shape, and match update cadence and serialization equality semantics. Define
whether memory reports used, available, pressure, or another existing contract
value by matching the public SDK—not by exposing Mach terms to Widgets.

**Gate:** System widget parity; deterministic serializer tests; subscriber
fan-out; zero collection when unsubscribed; sleep/wake and rapid subscribe/
unsubscribe; measured host idle cost with zero and multiple subscribers.

### PR 11 — Audio capture feasibility and shipping decision

**Repository:** Weaver documentation/ADR, with a disposable spike branch if
needed. This remains in the stack because its conclusion fixes the support
contract for every later PR.

Evaluate public capture paths on the intended minimum macOS version. Measure
permission prompts, denial/revocation, entitlements, signed versus unsigned
development, sandbox/notarization implications, capture of expected system
mixes, device changes, Bluetooth/AirPlay behavior, latency, CPU, and whether
one host capture can fan out to all Widgets. Reject private or distribution-
fragile shortcuts unless explicitly approved as a product tradeoff.

**Gate:** an ADR chooses the implementation, minimum macOS version, permission
story, fallback/unavailable behavior, and shipping constraints. Raw spike
results are attached. No production audio code lands without this decision.

### PR 12 — Production audio provider and Visualizer

**Repository:** Weaver, plus a Native SDK fork PR only if a genuinely generic
public capture seam is required.

Implement the chosen host-owned capture. Preserve the normalized mono sample
boundary and the existing shared FFT, 32 logarithmic bands, AGC, silence
decay, final zero, and traffic-suppression semantics. Permission denied,
revoked, device lost, silence, host shutdown, and resume must be distinguishable
in logs/status without changing Widget source. Capture exists only while at
least one enabled Widget subscribes.

**Gate:** live Visualizer; deterministic injected-sample FFT tests; audible →
decay → silence → resume; permission deny/allow/revoke; default-device and
output-route changes; multiple subscribers; host/widget crash recovery;
measured silent and active CPU/footprint.

### PR 13 — Media provider feasibility and shipping decision

**Repository:** Weaver documentation/ADR.

Determine whether system-wide now-playing metadata, playback state, position,
artwork, and controls can be implemented with public, distributable APIs at
the chosen support floor. `MPNowPlayingInfoCenter` being available does not by
itself prove that Weaver may observe other applications. Private MediaRemote
use requires an explicit product and distribution decision.

**Gate:** ADR states the supported media fields/actions, APIs, app coverage,
poll/push cadence, privacy/distribution constraints, and honest unavailable
behavior. If public parity is impossible, narrow the provider explicitly
rather than shipping a hidden private dependency.

### PR 14 — Production media provider

**Repository:** Weaver. Omit only if PR 13 explicitly decides that no honest
shippable implementation exists for this release.

Implement the approved host-owned media adapter behind the existing provider
shape. Preserve change-pushed metadata, the playing-position cadence, artwork
bounds, command errors, and subscription-driven lifetime. Do not leak player
bundle IDs or platform-only state into the SDK unless separately approved as a
cross-platform contract change.

**Gate:** Now Playing widget across the supported first-party and third-party
players; play/pause/seek if approved; player handoff, no active player,
sleep/wake, app quit, malformed/missing artwork, multiple subscribers, and
measured idle behavior.

### PR 15 — macOS CI, regression matrix, and release closure

**Repository:** Weaver, with final Native SDK fork cleanup PRs if earlier
evidence found issues.

Turn the accumulated commands into required macOS CI jobs. Keep fast
headless/unit jobs separate from hardware/session-dependent manual gates.
Document bootstrap, development, diagnostics, permission reset, known
limitations, and the support matrix in the README and result docs. Remove
temporary compile stubs and TODO allowances. Audit the whole diff for SDK
leaks, Windows regressions, orphaned processes, stale sockets, unsupported
claims, and accidental packaging commitments.

**Gate:** all automated suites green on Windows and macOS; every manual gate
below has current evidence; a clean clone on the supported Mac can complete
the Quickstart; no `weaverd`, `weaver-widget`, endpoint, temp install, or
permission helper remains after teardown.

## Required final verification matrix

### Functional

- Clock, Pomodoro, System, Now Playing when supported, Visualizer, DPI/
  placement diagnostic, and synthetic renderer parity fixtures.
- `init`, `check`, `bundle`, `dev`, `pack`, install from directory, install
  from `.weave`, replacement, rollback after failed replacement, uninstall,
  `up`, `down`, `status --json`, `logs`, and `logs --follow`.
- State-preserving bundle hot-swap and manifest-triggered restart.
- Network origin allow/deny, storage quota/persistence, assets, images,
  buttons/sliders, pointer input, and click-through.

### Window manager and display

- Bottom, normal, and topmost layers.
- Click-through and interactive Widgets; no activation or Dock/Command-Tab
  presence for widget-only processes.
- Primary and secondary displays at Retina and scaled resolutions, with
  displays arranged on every side of the primary.
- Mission Control, Show Desktop, all supported Spaces behavior, Stage Manager,
  fullscreen applications, lock/unlock, sleep/wake, screen reconnect, and
  menu-bar/Dock position changes.

### Reliability

- Widget crash, host crash, forced kill, malformed registry, missing source,
  bad bundle, renderer failure/fallback, provider permission denial, provider
  device loss, and interrupted install.
- Backoff timing, acknowledged reload failure, concurrent CLI writers, stale
  singleton/socket recovery, graceful shutdown, and forced termination.
- Repeated launch/close and install/uninstall loops with no process, descriptor,
  endpoint, observer, or GPU-resource growth.

### Performance and honest billing

- Clock private/footprint metric and idle CPU, with the macOS metric defined.
- Host alone, host plus one Widget, and host plus mixed software/Metal Widgets.
- Visualizer silent and active; provider unsubscribed versus subscribed.
- First visible frame, hot-swap latency, provider-to-present latency, and
  cadence over at least ten minutes.
- Software damage behavior, Metal resource cost, occluded behavior, and sleep/
  wake recovery. A `<=15 MiB` goal is retained, but the result must name the
  macOS metric and may not masquerade as Windows `PrivateUsage` parity.

## Definition of done

Lane D is complete only when:

1. A clean supported Mac completes the documented Quickstart and Conjure loop.
2. Current portable Widget source and `.weave` artifacts behave equivalently
   on Windows and macOS.
3. The daemon, runtime, software presenter, Metal presenter, providers, CLI,
   install boundary, hot-swap, status, logs, and teardown pass their gates.
4. Window behavior survives the macOS desktop-management matrix with recorded
   evidence.
5. macOS CI is required and Windows CI has remained green throughout the
   stack.
6. Every API or provider limitation is explicit; no private or unstable API is
   silently treated as shippable.
7. The two PR stacks have been reviewed and merged bottom-up, the superproject
   pins the final canonical Native SDK fork commit, and the working trees and
   submodule are clean.
