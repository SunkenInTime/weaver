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

Compatibility is the floor, not the aspiration. The macOS implementation
should use AppKit, Metal, Mach, IOSurface, event delivery, and other public
platform strengths aggressively behind Weaver's internal seams when they make
the product materially leaner. “It works on macOS” is not Lane D's success
condition; it should feel like Weaver's architecture was meant for macOS.

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
DirectComposition resources. macOS must earn its renderer architecture from
fresh measurements. The damage-aware software path is the correctness and
fallback baseline, not a predetermined default. Metal is a candidate default
for the entire Widget surface, including static retained Widgets, if it lowers
the total system bill while preserving identical SDK behavior and pixels.

The bakeoff must compare at least:

1. damage-aware software presentation;
2. one in-process Metal presenter per Widget;
3. an adaptive hybrid that retains unchanged content and sends only genuinely
   changing work to Metal;
4. a shared Metal service if per-process devices, queues, pipeline state,
   driver allocations, or threads scale badly;
5. a shared window/compositor owner with crash-isolated Widget logic processes
   only if a thinner shared-Metal design cannot remove the scaling cost.

Options 4 and 5 are research candidates, not foregone conclusions. A shared
design must use public, distributable macOS primitives and keep one
crash-isolated runtime/capability process per Widget. Moving every Widget's JS
logic into one process is not an acceptable optimization. The internal
generated `renderBackend` choice may change by platform; Widget source and the
public API may not.

The decision is made on total host + Widget + renderer cost for realistic
loads, not renderer FPS in isolation. Test one, three, and ten static Widgets;
mixed static/animated Widgets; and one and three 60 Hz synthetic Widgets.
Include cold and warm first frame, idle and active CPU, wakeups, energy impact,
thread count, file descriptors, process footprint, dirty/private memory,
compressed memory, Metal/IOSurface resource bytes, frame latency, cadence,
and teardown. Covered, occluded, all-Spaces, sleep/wake, and display-change
behavior are part of the performance result because a fast visible path that
polls while hidden is not lean.

The initial engineering targets to investigate include:

- share `MTLDevice`, command queues, immutable pipeline state, samplers, and
  shader libraries at the widest safe lifetime;
- ship precompiled Metal libraries instead of compiling shader source in each
  Widget at startup when packaging permits it;
- use the binary packet path and eliminate JSON parsing, per-frame Objective-C
  collections, temporary buffers, readbacks, and allocations from production
  presentation;
- keep retained pixels/textures resident and update only proven dirty regions;
- choose private versus shared storage modes from actual CPU/GPU ownership and
  avoid CPU-visible resources where no CPU access remains;
- reuse command buffers, upload rings, textures, scratch surfaces, and image/
  font resources with explicit bounded caches;
- make drawable acquisition and completion event-driven, cap frames in flight,
  and arm no display clock for a clean static Widget;
- lazily load Metal, AppKit-adjacent media frameworks, and provider machinery
  only when the selected Widget/provider needs them;
- audit thread stack reservations, framework imports, allocator peaks, logging,
  status sampling, provider polling, and IPC copies as part of the same bill.

Use Instruments Time Profiler, Allocations/VM Tracker, System Trace, Metal
System Trace, and Energy diagnostics alongside Weaver's own counters. Every
optimization must have a before/after workload capture. Do not keep an
optimization because it sounds native; keep it because the full workload got
measurably leaner without weakening correctness, crash isolation, fallback,
or API behavior.

### Whole-application leanness

The renderer bakeoff is the sharpest experiment, but the budget belongs to the
entire product. Every implementation PR must update a cost ledger for the
processes it affects. The host, every Widget runtime, an optional renderer,
provider workers, framework helpers, IPC, timers, and background wakeups all
count. Shared memory is not free merely because it is absent from one
process's private column, and moving work into a daemon does not erase it.

Prefer event-driven wakeups over probes; fixed-capacity/reused storage over
per-turn allocation; binary bounded transport over repeated JSON parsing in
hot paths; lazy framework/provider initialization over permanent imports; and
one shared collection over per-subscriber polling. Preserve the widget
capacity profile, QuickJS turn/memory limits, source/capability isolation, and
process-per-Widget failure boundary. Any proposal to spend more memory or
threads for lower latency must show the whole-workload tradeoff explicitly.

Performance is a continuous stack gate, not a cleanup PR at the end. A change
that regresses a previously measured idle, startup, memory, wakeup, or active
budget must explain and earn that regression in the PR where it occurs.

Backend reports, status output, demotion, recovery, frame cadence, damage,
alpha, images, text, input hit-testing, and canvas clocks must remain honest.
A requested but unavailable Metal backend must demote visibly to software or
fail explicitly; it may not report `metal` while presenting software pixels.
Software remains the recovery/reference path even if the bakeoff makes Metal
the default for every healthy Widget.

### Host and provider policy

Port the supervisor by extracting reusable behavior from the Win32 daemon,
not by copying `host/src/main.zig` into a second daemon. The macOS host needs:

- per-user singleton ownership and acknowledged reload/down commands;
- widget spawn, graceful shutdown, forced termination, crash detection, and
  the existing backoff semantics;
- atomic registry/status handling and install-owned source semantics;
- per-widget provider endpoints and subscription-driven provider lifetime;
- process PID, thread count, CPU, and a documented macOS footprint metric;
- software/Metal status and the selected macOS renderer lifecycle without
  ever launching the Windows renderer binary;
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

### PR 06 — Whole-system renderer bakeoff and architecture decision

**Repositories:** Native SDK fork spike PR plus Weaver measurement/ADR PR.

Build the smallest honest harnesses needed to compare software, in-process
Metal, retained/immediate hybrid, and a shared-Metal proof when per-process
costs warrant it. Do not optimize only the animated synthetic case: include
static Clock/Pomodoro, mixed real Widgets, and 1/3/10-Widget scaling. Instrument
packet construction, decode, retained planning, texture upload, command encode,
drawable wait, GPU completion, and application-loop dispatch separately.

Specifically audit the existing AppKit presenter's per-view Metal device and
queue ownership, runtime shader compilation, shared-storage textures,
Objective-C packet/object construction, scratch texture pool, verification
readbacks, image uploads, and completion handlers. Establish which paths are
debug/automation-only and ensure they disappear from production cost. Prototype
precompiled metallib loading, process-wide immutable resource caches, bounded
upload/resource reuse, binary packets, and a static clean-frame fast path.

If one in-process Metal stack per Widget scales poorly, prototype public
IOSurface/Metal sharing or another public thin-presentation design. Measure a
shared service against its IPC, process, synchronization, fallback, window,
and input costs. The spike may conclude that in-process Metal already wins;
it may not skip the scaling measurement.

**Gate:** a renderer ADR selects the default and fallback architecture using
captured whole-workload numbers. It states whether all healthy Widgets use
Metal, whether backend choice remains adaptive, whether a shared service is
required, which resources are shared, and why the rejected designs lose. All
candidates pass the same pixel/API/input tests before their performance is
compared. No production default changes in the measurement PR.

### PR 07 — Production lean Metal/rendering architecture

**Repositories:** Native SDK fork PR 03 (and additional stacked fork PRs if
the chosen shared design requires them), plus Weaver.

Implement the PR 06 decision completely. Metal may become the default for the
entire macOS Widget surface when that is the measured winner; no Widget source
or public API change is allowed. Land the selected device/queue/pipeline/
texture lifetime, binary command path, retained/damage policy, resource reuse,
static parking, occlusion pacing, and lazy initialization. Implement honest
software fallback, live demotion/recovery, and status/cost attribution. A
shared service, if chosen, starts only while needed and may never own Widget JS
logic or capability state.

**Gate:** Clock, Pomodoro, System, Visualizer, Now Playing when available, and
synthetic parity fixtures pass in the chosen default and forced-software
reference paths. Pixel/input/API parity, cold/warm first frame, 1/3/10 scaling,
10-minute active cadence, 10-minute static idle, covered/occluded behavior,
sleep/wake, display changes, repeated launch/close, crash/demotion/recovery,
and resource-growth tests pass. The result document includes total cost across
every participating process and before/after Instruments captures.

### PR 08 — Cross-platform CLI and artifact lifecycle

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
Host-dependent commands remain clearly unavailable until PR 10.

### PR 09 — Extract the portable supervisor core

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

### PR 10 — macOS daemon, IPC, status, and `weaver dev`

**Repository:** Weaver.

Implement the macOS host adapter: singleton/control channel, acknowledged
reload, Unix-domain provider endpoints, child spawn/environment, graceful and
forced termination, crash observation, stale endpoint cleanup, process CPU/
thread/footprint metrics, and the renderer lifecycle selected by PR 06. Wire CLI
`up`, `down`, `status`, `logs`, install reload, uninstall reload, and
`weaver dev` to it. Preserve stateful in-process hot-swap when only the bundle
changes and restart only when the manifest/window contract changes.

**Gate:** the complete Conjure loop works: init → dev → edit → state-preserving
hot-swap → stop. Install/replace/uninstall is acknowledged and leaves no
process or endpoint behind. Kill the host and Widgets in adverse orders and
verify recovery/backoff/status. Run concurrent CLI registry mutations.

### PR 11 — CPU and memory providers

**Repository:** Weaver.

Implement host-owned macOS CPU and memory collection through public system
APIs. Keep collection subscription-driven, emit the existing provider JSON
shape, and match update cadence and serialization equality semantics. Define
whether memory reports used, available, pressure, or another existing contract
value by matching the public SDK—not by exposing Mach terms to Widgets.

**Gate:** System widget parity; deterministic serializer tests; subscriber
fan-out; zero collection when unsubscribed; sleep/wake and rapid subscribe/
unsubscribe; measured host idle cost with zero and multiple subscribers.

### PR 12 — Audio capture feasibility and shipping decision

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

### PR 13 — Production audio provider and Visualizer

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

### PR 14 — Media provider feasibility and shipping decision

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

### PR 15 — Production media provider

**Repository:** Weaver. Omit only if PR 14 explicitly decides that no honest
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

### PR 16 — macOS CI, regression matrix, and release closure

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
- Host alone; host plus 1/3/10 static Widgets; mixed static/animated Widgets;
  and 1/3 sustained 60 Hz Widgets, with totals across all processes.
- Visualizer silent and active; provider unsubscribed versus subscribed.
- Cold and warm first visible frame, hot-swap latency, provider-to-present
  latency, input-to-present latency, and cadence over at least ten minutes.
- CPU, wakeups, energy impact, threads, descriptors, dirty/private and
  compressed memory, process footprint, Metal/IOSurface bytes, frames in
  flight, upload bytes, and allocation/high-water counts.
- Software damage behavior, retained-cache behavior, Metal resource cost,
  shared-renderer cost when selected, covered/occluded behavior, and sleep/
  wake recovery. A `<=15 MiB` goal is retained for a quiet Widget, but the
  result must name the macOS metric and may not masquerade as Windows
  `PrivateUsage` parity. Aggregate 3/10-Widget scaling is equally important;
  optimizing a single process while total cost grows linearly is not a win.

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
8. The renderer ADR proves the selected macOS architecture against software,
   in-process Metal, hybrid, and shared candidates; the implementation meets
   its whole-application cost ledger without changing Widget API behavior.
