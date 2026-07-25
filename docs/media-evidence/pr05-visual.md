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
