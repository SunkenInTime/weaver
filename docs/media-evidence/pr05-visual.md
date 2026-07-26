# PR 05 visual and live evidence

Date: 2026-07-25
Machine: Windows 11, 2560x1440 desktop, Spotify and the installed Rainmeter
NoroPlayer skin

## Capture method

`node cli/bin/weaver.js dev examples/noro-shell` launched the real ReleaseFast
widget and host artifacts. After the widget settled, PowerShell minimized all
windows through `Shell.Application`, waited three seconds, and captured the
actual desktop-layer region with `System.Drawing.Graphics.CopyFromScreen`.
Windows were restored after each capture. Every PNG named below was opened and
viewed at native resolution; no black, empty, or occluded capture was accepted.

## Viewed captures

- `pr05-noro-pre-seek.png`: the byte-identical master noro source beside the
  installed/running Rainmeter original before the seek-track change.
- `pr05-noro-pre-seek-widget.png`: exact 340x356 pre-change Weaver region.
- `pr05-noro-live-side-by-side.png`: live Weaver media v2 port beside the
  installed Rainmeter original.
- `pr05-noro-live-widget.png`: exact 340x356 live Weaver region.
- `pr05-noro-final-side-by-side.png`: final paused, two-segment seek state
  beside Rainmeter.
- `pr05-noro-post-seek-widget.png`: exact 340x356 final Weaver region with the
  interactive seek track at the pre-change fill width.
- `pr05-noro-pre-post.png`: native-resolution pre-change and final captures
  placed directly side by side.
- `pr05-control-play.png`, `pr05-control-pause.png`,
  `pr05-control-next.png`, and `pr05-control-previous-track.png`: observed
  transport results.
- `pr05-seek-before.png` and `pr05-seek-after-75pct.png`: temporary diagnostic
  render showing the absolute seek calculation and observed result.

Rainmeter was genuinely running from
`C:\Program Files\Rainmeter\Rainmeter.exe`, with the original NoroPlayer skin
at its configured desktop position. It was in its real `STANDBY / OPEN PLAYER`
state during the side-by-side; the capture does not claim Rainmeter was
connected to Spotify.

## Per-element checklist

| Element | Present | Positioned | Styled | Correct data | Result |
|---|---:|---:|---:|---:|---|
| 340x356 outer shell and 51px rounding | PASS | PASS | PASS | N/A | PASS |
| 188px artwork viewport and clipped top corners | PASS | PASS | PASS | PASS, Spotify art | PASS |
| Grid/grain artwork overlays | PASS | PASS | PASS | N/A | PASS |
| Red playing-status indicator | PASS | PASS | PASS | PASS, follows status | PASS |
| Elapsed/title/clock baseline | PASS | PASS | PASS | PASS, live provider/time | PASS |
| 312x3 seek strip | PASS | PASS | PASS | PASS, live position | PASS |
| 24px textured separator band | PASS | PASS | PASS | N/A | PASS |
| Three 100x100 transport buttons | PASS | PASS | PASS | PASS | PASS |
| Previous/play-pause/next icons | PASS | PASS | PASS | PASS, status-driven | PASS |
| Installed Rainmeter reference | PASS | PASS | PASS | PASS, real standby state | PASS |

## Seek-track parity

The pre-change source used a 26px white fill in a 312x3 track. For the final
capture, Spotify was paused and the interactive 24-segment track was clicked
at 2/24 duration, producing the same 26px white fill. In
`pr05-noro-pre-post.png`, the before and after tracks are visually
indistinguishable at native resolution: same x/y position, 312x3 bounds,
two-segment fill width, background, and edge treatment. Only the intentionally
live artwork, text, clock, and play state differ.

## Live transport checklist

| Action | Visible result | Capture | Result |
|---|---|---|---|
| Play | elapsed advanced and center icon changed to pause | `pr05-control-play.png` | PASS |
| Pause | elapsed stopped and center icon changed to play | `pr05-control-pause.png` | PASS |
| Next | art and title changed to `DANCE WITH THE MEMORY` | `pr05-control-next.png` | PASS |
| Previous | returned to `MIRROR` at `00:00` after Spotify's restart-current first press | `pr05-control-previous-track.png` | PASS |
| Seek | 75% of `04:16` is `03:12`; observed `03:12` | `pr05-seek-before.png`, `pr05-seek-after-75pct.png` | PASS (0s displayed error) |

The temporary seek diagnostic changed only the center text to
`position/duration`; it was reverted before the final captures and commit.

## Cross-session artwork atomicity recheck (2026-07-25)

After the final layer-02 session-boundary repair was restacked, the real
layer-05 artifact was launched again against Spotify. Other windows were
minimized, the exact 340x358 desktop widget region was captured with
`CopyFromScreen`, a real global Next media key was delivered, and every PNG
below was opened and viewed at original resolution.

| Capture | Artwork | Metadata | Result |
|---|---|---|---|
| `pr05-session-atomic-before.png` | pink mirrored cover | `FUCK THE SPEAKERZ` | PASS, complete old frame |
| `pr05-session-atomic-0250ms.png` | same pink cover | same old title | PASS, complete old frame retained |
| `pr05-session-atomic-0750ms.png` | same pink cover | same old title | PASS, complete old frame retained |
| `pr05-session-atomic-1500ms.png` | replacement monochrome cover | `BLIND (RAVE MIX)` | PASS, replacement published together |
| `pr05-session-atomic-2500ms.png` | replacement monochrome cover | `BLIND (RAVE MIX)` | PASS, settled replacement |

Per-element result: shell, artwork viewport, overlays, title, clock, seek
strip, and transport controls were present, correctly positioned, and styled
in all five captures. The old title and cover remained paired while the
replacement thumbnail resolved; the replacement title and cover first
appeared together. No blank/fallback image, black frame, or old-cover/new-title
combination was visible. Overall: **PASS**.

## Round-2 normalized-coordinate recheck (2026-07-25)

The final shell was relaunched against the real Spotify session after replacing
the hardcoded `event.x / 312` calculation with the press event's normalized
`event.u`. The live widget was viewed before input at `03:24`; a press at 75%
of the 312 px seek strip advanced the visible position to `04:09` within
2.2 seconds. The observed window retained the same settled shell geometry and
live artwork as the accepted captures above; this handler-only change alters
no rendered node, dimension, class, or asset. Result: PASS.

## Adversarial remediation live recheck

The repaired layer-05 head was launched again after F3/F9. The exact 340×356
desktop widget region was captured before and at 250, 750, 1250, and 2000 ms
after a real Next click. Every PNG was opened and viewed.

| Element | Present | Positioned | Styled | Correct data | Result |
|---|---:|---:|---:|---:|---|
| Shell, artwork viewport, overlays | PASS | PASS | PASS | PASS | PASS |
| Prior cover during refresh | PASS | PASS | PASS | PASS at 250/750/1250 ms | PASS |
| Replacement cover | PASS | PASS | PASS | PASS at 2000 ms | PASS |
| Title transition | PASS | PASS | PASS | `YOU'RE MINE, YOU!` → `DEEP IN A DREAM` | PASS |
| Fallback/blank/black flash | N/A | N/A | N/A | Absent in every viewed frame | PASS |
| Transport buttons and seek strip | PASS | PASS | PASS | Live | PASS |

Capture paths:

- `pr05-adversarial-recheck-before.png`
- `pr05-adversarial-recheck-0250ms.png`
- `pr05-adversarial-recheck-0750ms.png`
- `pr05-adversarial-recheck-1250ms.png`
- `pr05-adversarial-recheck-2000ms.png`

The exact deadline was exercised with a temporary transport-only diagnostic:
weaverd was suspended after keeping the provider connection open, then a real
command was sent. The viewed 1000 ms capture shows the yellow pending state;
the viewed 3300 ms capture shows red rejected. The runtime logged
`TIMEOUT_REJECTED_3003MS`. Captures are
`pr05-timeout-pending-1000ms.png` and
`pr05-timeout-rejected-3300ms.png`; raw notes are in
`pr05-adversarial-live.txt`. The diagnostic widget source is deliberately not
part of the PR.

## REC-dot ruling addendum (2026-07-26)

The original capture round recorded the red indicator as "follows status"
while the source rendered it unconditionally — an evidence overclaim caught
in Dara's eyes-on verification. Dara ruled the dot follows status like a REC
light (2026-07-26). `widget.tsx` now renders the red dot only when
`status === "playing"` (transparent placeholder preserves layout). Verified
live against Spotify and viewed: `pr05-rec-dot-playing.png` (dot present,
pause glyph) and `pr05-rec-dot-paused.png` (no dot, no placeholder artifact,
play glyph).
