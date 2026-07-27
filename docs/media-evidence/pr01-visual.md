# Media PR 01 visual and live evidence

Date: 2026-07-25

Machine: Windows 11, Spotify Premium desktop client

Example: `examples/now-playing`

The example passed `weaver check` and ran under `weaver dev`. The widget window
rectangle was read from the real `weaver-widget.exe` window. Other windows were
minimized through `Shell.Application.MinimizeAll`, the exact 360x142 region was
captured with `System.Drawing.Graphics.CopyFromScreen`, and each PNG below was
opened and viewed at original resolution.

## Paused frame

Capture: `docs/media-evidence/pr01-now-playing.png`

| Element | Present | Positioned | Styled | Correct live data | Result |
|---|---|---|---|---|---|
| Rounded dark shell | yes | fills 360x142 capture | rounded corners, translucent-dark surface | n/a | PASS |
| Now-playing marker and label | yes | top-left | purple marker and label | n/a | PASS |
| Playback status | yes | top-right | muted uppercase text | `PAUSED` while Spotify was paused | PASS |
| Track title | yes | first metadata line | large white text | `Music Baby (leroy Remix)` | PASS |
| Artist | yes | second metadata line | muted gray text | `Jane Remover` | PASS |
| Source application | yes | third metadata line | smaller muted text | honest raw SMTC ID `Spotify.exe` | PASS |
| Segmented progress | yes | bottom row | purple filled and slate unfilled segments | nonzero live timeline | PASS |

## Playing frame

Capture: `docs/media-evidence/pr01-now-playing-playing.png`

| Element | Present | Positioned | Styled | Correct live data | Result |
|---|---|---|---|---|---|
| Playback status | yes | top-right | muted uppercase text | changed to `PLAYING` within the next poll after sending the real player play/pause command | PASS |
| Track metadata | yes | unchanged metadata area | unchanged styling | title, artist, and source remained live and correct | PASS |
| Progress | yes | bottom row | unchanged styling | advanced while playing | PASS |

No capture was black, empty, or occluded. All visual checklist items pass.
