# macOS audio uses one host-owned Core Audio process tap and requires macOS 14.2

The macOS audio provider uses the public Core Audio process-tap API introduced
in macOS 14.2. One private, unmuted `CATapDescription` mixes global outgoing
process audio to mono, excluding Weaver itself, and supplies one private HAL
aggregate device and one IO proc. The callback crosses a bounded internal
sample queue into the host's existing shared audio analysis. Weaver performs
one capture and one FFT/AGC/silence pipeline, then fans the resulting provider
frame out to every subscribed Widget. Subscriber count must not multiply taps,
IO procs, or FFT work.

This decision raises Weaver's final macOS floor from the provisional 13.0 to
14.2. Older systems fail the host prerequisite explicitly; there is no hidden
ScreenCaptureKit, virtual-driver, microphone, or silent-zero fallback. Widget
source and `@weaver/sdk` keep the same platform-neutral `audio` contract.

The host executable must ship inside an identifiable agent application bundle
with the stable bundle ID `com.sunkenintime.weaver.host` and an
`NSAudioCaptureUsageDescription`. Developer builds are explicitly ad-hoc
signed; a truly unsigned arm64 executable is not runnable. Stable public
distribution requires Developer ID signing and notarization. The initial
developer distribution remains outside App Sandbox; this ADR makes no Mac App
Store or sandbox compatibility claim and adds no driver or private entitlement.

Authorization is a deliberate setup action, not an incidental subscription
side effect. `weaver audio authorize` launches a bounded authorization mode of
the same host bundle identity in the foreground. The normal daemon never asks
for first-time consent on its supervision thread. A successful authorization
writes a Weaver-owned marker; absence of that marker reports
`authorization-required` without attempting capture. A local rebuild may
change an ad-hoc identity and require authorization again. PR 13 owns this CLI
flow, the agent bundle, and a provider worker that cannot stall supervision if
Core Audio blocks while the system permission UI is active.

The internal availability reasons are `unsupported-os`,
`authorization-required`, `permission-denied`, `permission-revoked`,
`device-unavailable`, and `capture-failed`. They are visible in host status and
logs, not Widget source. Permission loss or device loss decays the shared audio
state to one final zero frame and then sends nothing; it must never masquerade
as live silence. Recovery restarts the one capture and resumes normal frames.

The tap is global rather than pinned to one `deviceUID`, so ordinary default
output changes remain inside the system mix. PR 13 listens to relevant HAL
device/tap changes, rebuilds the private aggregate when necessary, and proves
routes available on the test hardware. Bluetooth and AirPlay remain the same
global-capture policy, but are explicitly unverified until physical routes are
available. Protected streams that macOS declines to expose stay unavailable;
Weaver does not bypass system policy.

ScreenCaptureKit is rejected even though it supports older macOS releases: it
couples an audio-only provider to Screen Recording permission, shareable-content
selection, and video capture machinery. Audio Server plug-ins, BlackHole-style
virtual devices, kernel/system extensions, and private APIs are rejected
because they add installation or distribution fragility. Per-Widget taps are
rejected because they duplicate consent-sensitive system work and violate
host-owned provider fan-out.

The PR 12 spike proved public tap/format/private-aggregate setup, signing
boundaries, and the permission call site. Live mix, denial, revocation,
Bluetooth/AirPlay, route-change, active CPU, and callback latency remain
`UNVERIFIED` because the fresh system-audio prompt could not be controlled on
the unattended machine. PR 13 must close every available live gate without
weakening this decision; blocked physical routes remain named rather than
inferred.
