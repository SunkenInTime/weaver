# macOS M9 — audio capture feasibility and shipping decision

Recorded 2026-07-15 on a MacBook Air with Apple M2 (8 cores, 8 GB), macOS
26.5.1 (25F80), arm64, Xcode 16.0 (16A242d), the macOS 15 SDK, and Apple
clang 16.0. The disposable spike is Weaver commit `a3c7988` on
`macos/12-audio-decision`; Native SDK remains `359f5c9c`. Raw values are in
[`macos-m9-data.json`](macos-m9-data.json), and the decision is
[ADR 0014](adr/0014-macos-audio-core-audio-process-tap.md).

## Claim and non-goals

The shipping route is one host-owned public Core Audio process tap on macOS
14.2 or newer. It is global, private, unmuted, mono, and not pinned to a device.
One callback supplies the existing shared FFT/AGC/silence pipeline; provider
fan-out remains software work after that one capture. The host becomes a signed
agent bundle with a stable identity, and authorization becomes an explicit CLI
step using that same identity.

This PR does not land production capture, claim a successful permission grant,
or claim live latency/cost/device-route results. It does not add a driver,
ScreenCaptureKit fallback, private API, sandbox entitlement, or platform term
to Widget source.

Apple's public sample describes a tap as an input of a HAL aggregate device,
requires macOS 14.2, requires `NSAudioCaptureUsageDescription`, and says the
first aggregate-device recording triggers System Audio Recording permission:
[Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
The installed SDK independently marks `AudioHardwareCreateProcessTap` as
available from macOS 14.2. Apple's
[`NSAudioCaptureUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)
reference defines it specifically for system audio.

ScreenCaptureKit is rejected for this provider. Apple documents it as combined
screen/audio capture that requires Screen Recording permission and recommends a
system content-sharing picker, which is the wrong consent and product surface
for an audio-only host provider:
[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit).

## Automated and physical evidence

| Case | Exit/result | Evidence |
|---|---:|---|
| Build app at a 14.2 deployment target | 0 | Objective-C/ARC spike linked only Foundation + public Core Audio; Mach-O reports `minos 14.2` |
| Linker-ad-hoc unbundled setup | 0 | tap, UID, 48 kHz Float32 mono format, and private aggregate all returned `OSStatus 0`; no IO proc attempted |
| Explicit ad-hoc signed bundle setup | 0 | same public setup result; bundle identity and 10 Info.plist entries are sealed by the signature |
| Truly unsigned arm64 setup | 137 | kernel terminated the binary before `main`; no result file |
| Fresh signed bundle capture | bounded timeout | scoped `tccutil reset All` passed; after six seconds the main thread remained in `AudioDeviceCreateIOProcIDWithBlock` → HAL → `mach_msg2_trap`; no result was fabricated |
| Cleanup | 0 | capture process killed, scoped TCC decision reset, and no Weaver tap/aggregate remained |

Chronicle was not running and System Events automation also blocked, so the
ordinary system permission dialog could not be inspected or accepted. This is
an `UNVERIFIED` permission gate, not a denial result. The earlier
ScreenCaptureKit path is independently blocked with `SCStreamErrorDomain
Code=-3801` and therefore provides no safe unattended alternative.

The active machine has built-in speakers plus BlackHole/aggregate virtual
routes, but no Bluetooth or AirPlay route. Because permission prevented IO proc
registration, audible mix, default-route change, Bluetooth/AirPlay, denial,
revocation, first-signal latency, and capture recovery remain `UNVERIFIED`.
The global non-device-pinned design is selected, while PR 13 owns the live
listeners and every physical route actually present then.

## Cost boundary

Ten setup-only processes each created and destroyed the tap and aggregate,
with a deliberate 0.5 second sleep. Mean wall time was 0.610 seconds, summed
user+system time was 0.014 seconds, and mean maximum RSS was 14,209,843 bytes.
The derived 2.295% CPU covers process startup/setup across that wall boundary;
it is not steady capture cost. No active/silent capture CPU, callback latency,
wakeup, energy, or fan-out performance claim is made before permission allows
real callbacks.

## Shipping constraints and next gate

- Final minimum macOS is 14.2. README and CI/package metadata must agree.
- `weaverd` ships as `com.sunkenintime.weaver.host`, an `LSUIElement` agent
  bundle containing `NSAudioCaptureUsageDescription`.
- Local developer builds are ad-hoc signed and may need reauthorization after
  rebuild. Stable distribution requires Developer ID signing and notarization;
  neither is inferred from the local `gdb-cert` identity.
- Initial distribution is non-sandboxed. Mac App Store/App Sandbox support is
  not claimed.
- Missing authorization and capture failures report explicit internal
  availability reasons and emit no fake live-silence frames.
- PR 13 must implement explicit authorization, bounded provider-worker
  isolation, one-capture/multi-subscriber fan-out, final-zero semantics,
  route/revocation recovery, deterministic injected FFT tests, and live cost
  evidence wherever the machine permission/hardware allows it.

PR 12 rolls back independently by reverting the spike, ADR, floor, and
contract wording. No production provider code is present to unwind.
