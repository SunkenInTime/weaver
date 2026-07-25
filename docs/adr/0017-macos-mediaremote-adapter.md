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
process, and only exit 0 with empty stdout is a successful delivery. Command
success does not claim that the next observation has already settled.

This route is isolated behind `host/src/providers_macos.zig` and the existing
per-widget UDS. Widgets see the same media frame-v2 and verb/ack protocol as
Windows. Apple breakage or a later replacement with per-application
AppleScript changes no widget source, SDK type, manifest declaration, wire
key, or UDS ownership rule.

Helper EOF, malformed output, or child exit is adapter loss. Weaver emits one
canonical empty media frame, reports `mediaAvailability: "unavailable"` in
host diagnostics, then stays silent while restarting with bounded backoff.
It never fabricates player data. A valid full frame restores availability and
rebuilds state; an empty payload from a live helper remains an honest
no-session observation.

The private-symbol route is not eligible for the Mac App Store. Weaver vendors
the helper and its BSD-3-Clause license in its own install layout and never
invokes a Homebrew path. Direct distribution requires Developer ID signing of
every executable artifact with hardened runtime and secure timestamp,
notarization of the complete app, and a quarantined Gatekeeper execution test.
The attended spike proves the route on an M2 Mac running macOS 26.5.1; it does
not prove that Weaver's implementation or a shipping notarized bundle has
passed those live gates.
