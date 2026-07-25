# Media PR 03 visual and live evidence

Date: 2026-07-25

Machine: Windows 11, 2560×1440 primary display, Spotify Premium

Artifact: `node cli/bin/weaver.js dev examples/now-playing`

The committed example ran on the real desktop layer and was allowed to settle.
Other windows were minimized with `Shell.Application.MinimizeAll()`. The
widget's physical screen region was captured with
`System.Drawing.Graphics.CopyFromScreen`, then every accepted PNG below was
reopened with the image-viewing tool at original resolution.

The first live attempt exposed a blocking duplex defect: a synchronous
command-reader `ReadFile` on the Windows server handle serialized the host's
first provider `WriteFile`, so status stopped advancing. A bounded startup
trace localized the block to that 333-byte write. Both ends of the Windows
pipe now use overlapped I/O; the reader thread still blocks on its own event,
the host loop remains the sole writer, writes have a one-second bound, and
shutdown cancels outstanding operations. The repaired host status advanced
every two seconds and the live checks below passed. No pre-fix capture is
accepted as evidence.

## Committed now-playing example

Playing capture: `docs/media-evidence/pr03-now-playing-live.png`

Paused-through-widget capture:
`docs/media-evidence/pr03-now-playing-paused.png`

Later-track paused capture:
`docs/media-evidence/pr03-now-playing-final-paused.png`

| Element | Present | Positioned | Styled | Correct data | Result |
|---|---:|---:|---:|---:|---|
| Rounded translucent shell | yes | yes | yes | n/a | PASS |
| Activity dot and `NOW PLAYING` label | yes | top-left | purple | yes | PASS |
| Play/pause button | yes | top-right | slate pill with hover/pressed states | `PLAYING · PAUSE` / `PAUSED · PLAY` | PASS |
| Album art | yes | 72×72 left slot | cover crop and rounded mask | live Spotify art for each track | PASS |
| Title and artist | yes | right of art | white title, muted artist | live Spotify metadata | PASS |
| Source application | yes | below artist | dim muted | `Spotify.exe` | PASS |
| Segmented progress | yes | bottom row | purple filled / slate empty | changes with live position and seek | PASS |

Overall: **PASS**. Both captures are nonempty, unobscured, fully framed, and
the committed button visibly changes the real player's state.

## Transport verb check

A temporary uncommitted widget declared `media-transport`, subscribed to
media for observable title/timeline data, called each SDK verb, and rendered
the settled promise result. It was removed after the check.

| Verb | Accepted capture | Observed result | Result |
|---|---|---|---|
| `play()` | `pr03-verb-play.png`, `pr03-verb-play-now-playing.png` | promise `true`; committed widget changed to `PLAYING · PAUSE` | PASS |
| `pause()` | `pr03-verb-pause.png`, `pr03-now-playing-final-paused.png` | promise `true`; committed widget changed to `PAUSED · PLAY` | PASS |
| `next()` | `pr03-verb-next.png` | promise `true`; title changed from `summer's end` to `Dance in the Memories` | PASS |
| `previous()` | `pr03-verb-previous-track.png` | promise `true`; Spotify moved to `Mirror` and reset the timeline | PASS |
| `seek(128000)` | `pr03-verb-seek.png` | promise `true`; 256-second track reported 129 seconds on the next sampled frame | PASS |

Seek landed within approximately one second of the 50% target. The one-second
provider cadence, not a separate polling loop, supplied all observable
metadata and timeline changes.

Performance claim: deliberately declined for this PR. Transport adds one
bounded reader thread to each widget with a provider endpoint, so this layer
does not repeat layer 02's static-image no-cost claim. The implementation adds
no transport polling loop; commands and acknowledgements are request-driven.
