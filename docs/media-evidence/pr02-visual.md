# Media PR 02 visual and live evidence

Date: 2026-07-25  
Machine: Windows 11, 2560×1440 primary display, Spotify Premium  
Artifact: `node cli/bin/weaver.js dev examples/now-playing`

The widget was allowed to settle on the real desktop layer. Other windows were
minimized with `Shell.Application.MinimizeAll()`, and the widget's physical
screen region was captured with `System.Drawing.Graphics.CopyFromScreen`.
Every accepted PNG below was reopened with the image-viewing tool at original
resolution.

The first correctly framed capture exposed a blocking defect: Spotify's valid
300×300 PNG decoded to 360,000 RGBA bytes, exceeding the widget profile's fixed
256 KiB image slot, and the art area was empty. The runtime log reported
`ImageTooLarge`. The host now aspect-fit normalizes oversized decoded artwork
to at most 256×256 before cache publication. The repaired cache object was
92,684 bytes, decoded to 256×256, and registered without an error. No failed
capture is accepted as evidence.

## Settled frame

Capture: `docs/media-evidence/pr02-now-playing.png`

| Element | Present | Positioned | Styled | Correct data | Result |
|---|---:|---:|---:|---:|---|
| Rounded translucent shell | yes | yes | yes | n/a | PASS |
| Purple activity dot and `NOW PLAYING` label | yes | yes | yes | yes | PASS |
| Playback status | yes | top-right | muted uppercase | `PAUSED` | PASS |
| Album art | yes | 72×72 left slot | cover crop, rounded mask | live Spotify art | PASS |
| Title | yes | right of art | white, largest text | `at thirst sight by Assia` | PASS |
| Artist | yes | below title | muted | `MIKE` | PASS |
| Source application | yes | below artist | dim muted | `Spotify.exe` | PASS |
| Segmented progress | yes | bottom row | purple filled / slate empty | live nonzero position | PASS |

Overall: **PASS**. The capture is nonempty, unobscured, fully framed, and the
host-provided image is visibly rendered.

## Track-change frame

Capture: `docs/media-evidence/pr02-now-playing-track-change.png`

A real `WM_APPCOMMAND/APPCOMMAND_MEDIA_NEXTTRACK` was delivered to Spotify.
The next changed media provider frame increased `mediaPipeFrames` from 2 to 3
and carried a newly published cache object after 1,798 ms wall time (including
Spotify's own transition latency). The cache object was 117,930 bytes and
decoded to 256×256.

| Element | Present | Positioned | Styled | Correct data | Result |
|---|---:|---:|---:|---:|---|
| Replacement album art | yes | same 72×72 slot | cover crop, rounded mask | visibly different live art | PASS |
| Replacement title | yes | unchanged title slot | white | `C.O.T.D` | PASS |
| Replacement artist | yes | unchanged artist slot | muted | `Coaltar Of The Deepers` | PASS |
| Playback status | yes | top-right | muted uppercase | `PLAYING` | PASS |
| Progress | yes | bottom row | purple/slate segments | reset near track start | PASS |

Overall: **PASS**. Art and metadata changed together on the next emitted media
frame; no intermediate frame pointed at a partial or missing cache file.

## Pause frame

Capture: `docs/media-evidence/pr02-now-playing-paused.png`

A real `WM_APPCOMMAND/APPCOMMAND_MEDIA_PLAY_PAUSE` was delivered to Spotify and
the provider was allowed two seconds to poll.

| Element | Present | Positioned | Styled | Correct data | Result |
|---|---:|---:|---:|---:|---|
| Current album art | yes | unchanged 72×72 slot | cover crop, rounded mask | retained `C.O.T.D` art | PASS |
| Current metadata | yes | unchanged metadata column | unchanged styling | retained live track | PASS |
| Playback status | yes | top-right | muted uppercase | changed to `PAUSED` | PASS |
| Progress | yes | bottom row | purple/slate segments | retained paused position | PASS |

Overall: **PASS**.
