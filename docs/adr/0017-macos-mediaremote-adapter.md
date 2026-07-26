# macOS system-wide media uses the isolated MediaRemote adapter

Status: accepted; supersedes ADR 0015.

Weaver observes the macOS system-wide Now Playing session through the
`ungive/mediaremote-adapter` v0.7.6 route proven by the 2026-07-25 attended-Mac
spike. Weaver invokes its vendored BSD-3-Clause helper through
`/usr/bin/perl`; that Apple platform-signed executable has identifier
`com.apple.perl` and supplies the qualifying identity on the macOS 15.4+
route. The helper framework resolves private MediaRemote symbols at runtime
with `CFBundleGetFunctionPointerForName`; Weaver does not link MediaRemote.

One supervised helper process emits newline-delimited, non-diff metadata
frames on stdout. Transport is not a bidirectional stdin protocol: each play,
pause, next, previous, or seek request launches a separate bounded helper
process. Exit 0 with empty stdout is successful delivery. Exit 2 is reserved
for a request that reached MediaRemote and was declined. Spawn or loader
failure, missing framework or symbols, timeout, signal death, unexpected
stdout, and every other process/channel failure reject the widget promise.

MediaRemote's elapsed-time setter is void, so seek never trusts the setter
call alone. The helper repeatedly reads Now Playing state until convergence or
the two-second deadline and accepts only an observed elapsed time within
2000 ms of the requested time, adjusted by the reported playback rate during
verification. Missing session, unavailable read-back, or an out-of-tolerance
value at the deadline is an OS decline and resolves `false`.

This route is isolated behind `host/src/providers_macos.zig` and the existing
per-widget UDS. Widgets see the same media frame-v2 and verb/ack protocol as
Windows. Apple breakage or a later replacement with per-application
AppleScript changes no widget source, SDK type, manifest declaration, wire
key, or UDS ownership rule.

Helper EOF, EOF with an unterminated residual record, malformed metadata or
artwork, or child exit is adapter loss. Weaver emits one canonical empty media
frame, reports `mediaAvailability: "unavailable"` in host diagnostics, then
stays silent while restarting with bounded exponential backoff. Backoff resets
only after at least one frame and 30 seconds of stable streaming. SIGTERM
teardown escalates to SIGKILL after one second. Weaver never fabricates player
data. A valid full frame restores availability and rebuilds state; an empty
payload from a live helper remains an honest no-session observation. A present
session with a blank title remains a session; absent playback state is
`"stopped"`. Timestamped elapsed time advances on Weaver's existing one-second
media publication clock using the adapter's validated playback rate. A helper
that remains alive but emits no complete first frame for 10 seconds is treated
as adapter loss: Weaver kills it, emits the same single empty/unavailable
transition, and enters the same bounded backoff.

Artwork crosses the same budget boundary as Windows: decode, aspect-fit to at
most 256×256 / 256 KiB decoded RGBA, PNG re-encode, then atomic art-cache
publication. Invalid base64, oversized input, decode failure, or an
out-of-budget normalized image is malformed adapter output and triggers the
adapter-loss behavior above.

The helper route is runtime-gated with `NSProcessInfo` to macOS 15.4 or newer.
Below that floor Weaver does not spawn the helper and reports media
unavailable. The attended spike ran on macOS 26.5.1; exact behavior at 15.4
remains **UNVERIFIED (needs attended Mac at that version)**.

The private-symbol route is not eligible for the Mac App Store. Weaver vendors
the helper and its BSD-3-Clause license in its own install layout and never
invokes a Homebrew path. Direct distribution requires Developer ID signing of
every executable artifact with hardened runtime and secure timestamp,
notarization of the complete app, and a quarantined Gatekeeper execution test.
The attended spike proves the route on an M2 Mac running macOS 26.5.1; it does
not prove that Weaver's implementation or a shipping notarized bundle has
passed those live gates.
