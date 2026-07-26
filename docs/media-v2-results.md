# Media v2 results

Date: 2026-07-25

## 2026-07-25 round-2 addendum

The second adversarial pass is implemented locally. The accepted state now
also includes a deadline-bounded macOS runtime send, race-free Windows reader
shutdown, binding- and signature-complete CLI capability detection,
crash-supervised recovery from a fatal shared provider channel, a 10-second
macOS first-frame watchdog, repeated seek read-back through the two-second
deadline, and validated playback-rate timeline math. The Noro seek handler now
uses `event.u`; a live Spotify recheck visibly advanced from `03:24` to `04:09`
after a 75% strip press without changing the rendered shell.

The Objective-C helper build/tests and hosted macOS session are **CI-pending**
at this commit. Real Weaver behavior for the new watchdog, non-1× advancement
and seek, and fatal-channel restart remains **UNVERIFIED (needs attended
Mac)**; the earlier spike still proves only the route.

## 2026-07-25 adversarial-remediation addendum

The historical macOS BLOCKED conclusion at the end of this file is
superseded. The standalone attended spike gate is **PASSED** per
`docs/media-evidence/pr04-mac-spike.md`. Layer 04 now implements the route and
passes the locally executable Windows, portable, release-audit, and macOS Zig
semantic gates. The implementation itself remains **UNVERIFIED (needs
attended Mac)**; the spike did not run Weaver's provider. Exact macOS 15.4
floor behavior is separately **UNVERIFIED (needs attended Mac at 15.4)**.

The accepted implementation state includes PID-bound endpoints, strict EOF
framing, idle-zero transport, exact command deadlines, structurally non-lossy
ack/nack lanes, truthful helper failure rejection, read-back-verified seek,
timestamped timeline advancement, normalized artwork, retained Windows art on
refresh failure, bounded platform waits/teardown, stable restart backoff, and
the runtime OS floor. The finding-by-finding evidence and remaining attended
matrix are in `docs/media-run-status.md`.

## Windows acceptance result

The Windows slice is complete through the noro gate:

- `examples/noro-shell` observes real `media` and `time` provider frames.
- The 188px screen area uses host-cached artwork when available and retains
  the bundled cover as a conditional fallback.
- Elapsed time, title, source status, and play/pause glyph are live.
- Existing previous, play/pause, and next buttons deliver real SMTC commands.
- The former static 312x3 progress stack is a pixel-matched click-to-seek
  button using the press event's normalized local `event.u`.
- `skills/conjure-widget/SKILL.md` teaches `MediaData.artPath`,
  `useMediaTransport`, the `media-transport` capability, and promise semantics.

The full viewed visual checklist and capture inventory are in
`docs/media-evidence/pr05-visual.md`.

## Live Windows result

Spotify was used as the real player. Art and metadata were already visible on
the first settled provider frame. Pause/play visibly changed the glyph and
timeline, next changed art/title, and previous returned to the prior track.

Seek was measured with a temporary diagnostic title. The track duration was
`04:16` (256 seconds); a click at 75% targeted 192 seconds and the next
provider frame displayed `03:12` (192 seconds). The diagnostic was reverted
before the final capture and commit.

The installed Rainmeter original was captured beside Weaver. Rainmeter was in
its genuine standby state, while Weaver was connected to Spotify; the evidence
therefore supports shell geometry/styling parity and Weaver's live state, not a
claim that both processes rendered the same media frame.

## Idle A/B

This is a controlled source-only A/B on the same machine and same media-v2
ReleaseFast runtime/host binaries. The baseline used
`examples/noro-shell/widget.tsx` byte-for-byte from `master`; the candidate
used the PR 05 source. Each process set settled for 40 seconds, then process
CPU, private bytes, and thread counts were sampled across approximately 60
seconds. Spotify was paused and stable.

| Metric | Master noro source | Media-v2 noro source | Difference |
|---|---:|---:|---:|
| Sample | 60.027s | 60.039s | +0.012s |
| Widget CPU | 0.000ms | 562.500ms | +562.500ms |
| Host CPU | 218.750ms | 359.375ms | +140.625ms |
| Combined CPU | 218.750ms | 921.875ms | +703.125ms |
| Combined CPU / one logical core | 0.364% | 1.535% | +1.171 percentage points |
| End private memory, widget + host | 41.81 MiB | 47.12 MiB | +5.31 MiB |
| End threads, widget + host | 8 | 17 | +9 |

Performance claim: explicitly declined. This single matched run measures the
cost of activating the Windows media provider, dynamic artwork path, timeline
updates, and transport endpoint. It does not support a no-regression or broad
benchmark claim. It does show bounded steady-state behavior over the measured
minute: candidate private memory changed by about 0.03 MiB during the sample.

## Historical macOS acceptance (superseded by the addendum above)

The original Windows-only run recorded PR 04 as spike-gated and BLOCKED
because it could not produce a real macOS metadata frame plus delivered
command. That historical decision is retained for provenance only. The later
attended route evidence passes the spike, while Weaver's remediated
implementation and the macOS noro side-by-side remain unverified as stated in
the dated addendum.
