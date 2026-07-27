# Skin parity targets — the beta acceptance bar

Set by Dara, 2026-07-27. **Before beta, Weaver must be able to 100% recreate
every skin on this list.** "100%" means the noro-player standard, which is the
proven template: a pixel-faithful side-by-side a stranger can't tell apart,
plus full functional parity (live data, working controls), verified attended
on both OSes with viewed captures.

This list is deliberately a *demand signal*: nothing on the API backlog (the
alive pack, new providers, new capability rungs) gets built speculatively —
it gets built when a skin on this list demands it. When planning any breadth
work, derive the requirement from a named skin here.

| # | Skin | Status | What it demands beyond today's surface |
|---|---|---|---|
| 0 | [noro-player](https://github.com/SunkenInTime/noro-player) | **DONE** (media v2 stack, 2026-07-27) | — the fidelity anchor |
| 1 | [Windows 12 Rainmeter](https://www.deviantart.com/linkvegas12/art/Windows-12-Start-Menu-Redesign-1051808614) | not started | Launcher UI: app grid + icons, **launch-app capability** (first loud-ladder rung, ADR 0002), blur/acrylic panels |
| 2 | [Droptop Four](https://droptopfour.com/) | not started | Global dropdown menu bar: hover-open nested menus, app launching, weather provider, per-monitor edge anchoring |
| 3 | [Fountain of Colors](https://www.deviantart.com/alatsombath/art/Fountain-of-Colors-desktop-music-visualizer-518894563) | not started | Audio visualizer: audio provider spectrum data → high-FPS animated bars (alive pack: canvas v2 + animation at 60fps with honest billing) |
| 4 | [Omnimo 10](https://omnimo.info/) | not started | Metro tile suite: RSS/mail/weather providers, tile grid composition, launcher, text input for search |
| 5 | [Mond](https://www.deviantart.com/apexxx-sensei/art/Mond-762455575) | not started | Minimal clock/media/search: web search box (**text input element**), launch-URL capability |
| 6 | [TETRACTYS](https://visual11themes.win/rainmeter-skin/tetractys-rainmeter-suite-skin/) | not started | Geometric monitors: canvas arcs/paths/gauges, rotated text, **network provider** (up/down rates) |
| 7 | [JaxCore](https://github.com/Jax-Core/JaxCore) | not started | The alive-pack stress test: spring/eased animations everywhere, blur, toggles, gesture-y interactions, module settings UI |
| 8 | [TECH-A](https://visualskins.com/skin/tech-a) | not started | Sci-fi HUD: circular gauges, segmented arcs, **GPU stats provider**, custom display fonts |
| 9 | [Neon Space](https://99villages.com/neon-space/) | not started | Neon glow: glow/bloom (shadow-as-glow or blur), gradients, visualizer bars |
| 10 | [90 Degrees](https://www.reddit.com/r/desktops/comments/1k92gll/noodles/) | not started | Minimal typography: **rotated text**, hairline rules, big display fonts |
| 11 | [Nord Rework Suite](https://www.deviantart.com/carlya5l/art/Nord-Rework-Rainmeter-Suite-1-2-1178689879) | not started | Themed suite: weather provider, media (done), launcher, consistent multi-widget suite packaging |
| 12 | [NERV UI](https://home.gamer.com.tw/artwork.php?sn=1956980) | not started | Evangelion HUD: aggressive clipped shapes, blink/alert animations, dense system stats |
| 13 | [Sonder](https://github.com/mpurses/Sonder) | not started | Typographic date/quotes/media: long-text layout, network-fetched quote data (declared origins — exists), font weights |
| 14 | [TranslucentTaskbar](https://www.deviantart.com/arkenthera/art/TranslucentTaskbar-1-2-656402039) | **needs a ruling** | Modifies the OS taskbar itself, not a desktop widget — likely out of Weaver's widget model entirely. Dara to rule: in scope (new system-surface capability, loud rung) or explicitly cut. |

## Derived capability backlog (what the list actually demands, deduped)

- **Providers:** weather, network rates, GPU stats, RSS/mail, audio spectrum
  (Windows exists — needs the widget-facing surface; macOS per ADR 0014).
- **Capability ladder (loud rungs, ADR 0002):** launch app, open URL. These
  are demanded by half the list and are also roadmap item 3's "grants next".
- **Alive pack, ordered by demand:** animation (3, 7, 9, 12) > blur/glow
  (1, 7, 9) > canvas gauges/arcs/paths (6, 8) > gradients (9).
- **Elements:** text input (4, 5), rotated text (6, 10).
- **Composition:** multi-widget suites with shared theme/packaging (2, 4, 11),
  screen-edge/monitor anchoring (2, 14).

## Where this sits in the roadmap

This is not a roadmap step; it is the **acceptance bar for beta** — the same
role the noro port played for the API-breadth slice, scaled up. Roadmap items
5 (remaining breadth), 3 (grants), and 10 (alive pack) should pull their
requirements from here; the gallery (item 7) is where these recreations
become the launch catalog. Recreations double as conjure-skill test fixtures
and gallery seed content.
