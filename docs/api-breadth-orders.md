# API breadth — ordered work list

Ordering set with Dara, 2026-07-21 (expanded same day with the full styling
sweep). This expands roadmap item 5. The driving goal right now is **styling
ease**: every gap here is something an agent hits within minutes of trying to
build a real widget. The acceptance gate for the whole list is a
pixel-faithful port of Dara's own Rainmeter skin,
[noro-player](https://github.com/SunkenInTime/noro-player) — it exercises most
of it (asymmetric-corner album art, text overlaid on the art, Cozette bitmap
font, inset-shadow buttons with pressed states, grain/grille texture tiles,
transport controls, seek, elapsed/duration).

Styling first (1–10), then the media provider work that makes the gate
functional (11–12), then the gate (13). The test for what belongs in 1–3 is
"an agent trained on Tailwind would type this without thinking and be
surprised it fails."

1. **Box-model + layout pack** (class compiler + renderer, no new node types)
   - Directional padding `px/py/pt/pr/pb/pl` and **margins** `m/mx/my/mt/...`
     (margins don't exist at all today — gap can't express asymmetric
     spacing).
   - Per-corner radii: `rounded-t-*`, `rounded-b-*`, `rounded-tl-*` etc.,
     including arbitrary values (`rounded-t-[36px] rounded-b-[4px]` is
     literally the noro screen).
   - Borders: `border`, `border-N`, `border-[#hex]`; per-side is fine to
     defer.
   - Sizing: `w-full`/`h-full`, `w-auto`, fractions (`w-1/2`), `size-N`,
     `min-w/max-w/min-h/max-h` (max-w is what makes `truncate` actually
     useful), `aspect-square`/`aspect-[4/3]`.
   - Flex completeness: `justify-around/evenly`, `shrink`/`shrink-0`,
     arbitrary `grow-N`, `self-*`, `flex-wrap`.
2. **Text pack**
   - `text-left/center/right` (alignment today is only achievable with flex
     gymnastics).
   - Arbitrary font size `text-[13px]`, line height `leading-*`, letter
     spacing `tracking-*` (retro/display faces live on tracking).
   - `line-clamp-N` multi-line ellipsis to go with single-line `truncate`.
   - `tabular-nums` — fixed-width digits. Without it every clock and timer
     jitters horizontally each tick; table stakes for a widget platform.
3. **Tailwind color palette names** — `bg-zinc-900`, `text-slate-400/70`,
   the standard palette, compiled to the hex values agents already expect.
   Pure lookup table in the class compiler, zero renderer work, and it's the
   single highest-leverage item for agent output quality: models reach for
   palette names before hex every time.
4. **Shadows**, including inset (the whole tactile-button look) and
   `text-shadow` while we're in there.
5. **Font families** — fonts ship in the widget bundle (source-is-the-
   artifact — a `.ttf` next to `widget.tsx`), `font-[cozette]` utility
   resolved against bundled files, validated by `weaver check` with fix-its.
   Plus built-in `font-sans`/`font-mono` mapped to system faces — bundling a
   file must not be the only way off the default face.
6. **Icons** — `<icon name="play" />` backed by a vendored open icon set
   (Lucide-style names — squarely in agents' training distribution),
   rendered natively and tinted/sized via the same class utilities as text.
   Today there is no icon story at all; noro's prev/play/next glyphs would
   be hand-drawn canvas polylines.
7. **`<stack>` overlay primitive + clipping** — children paint in order,
   each child aligned/inset within the stack; `overflow-hidden` clips
   children to the node's rounded bounds (stack makes overflow reachable, so
   they land together). This is the obvious answer to "text on top of album
   art" — a sibling to `<row>`/`<column>`, not CSS `absolute` (we are not
   reimplementing positioned layout).
8. **Image v2**: `object-fit` cover/contain, clipping to the node's rounded
   corners, and repeat/tiling (grain + grille textures are tiled PNGs).
   Source stays local-path; provider-supplied images arrive as paths (see
   11).
9. **Interaction pack**
   - `pressed:` (and probably `hover:`) class variants on interactive
     elements, compiled to a second prop set the runtime swaps natively —
     no JS round-trip per press.
   - Pointer position on click events (normalized 0–1 within the element) —
     "user clicked 62% along the progress bar" is how seek works.
   - `<slider>` primitive on top of that so agents don't reimplement drag
     math badly; double-click and right-click events (noro opens the player
     on double-click).
10. **Alive pack** (needs renderer work; order within this item is open)
   - Gradients: `bg-gradient-to-*` with `from-/via-/to-` (currently rejected).
   - Transforms: `rotate-*`, `scale-*`, `translate-*` incl. arbitrary —
     analog clock hands stop requiring canvas trig.
   - Motion: `transition` on pressed/hover swaps, plus the preset
     `animate-spin/pulse/bounce` trio, driven natively so idle-zero and
     honest billing hold (ADR 0005 — an animating widget is *supposed* to
     bill).
   - `blur-*`/`backdrop-blur-*` within widget content. True
     glass-over-wallpaper is a windowing/compositor feature with a real cost
     story — separate decision, not smuggled in here.
   - Canvas v2 to match: text drawing, image blit, arcs/paths, gradient
     fills, stroked shapes (today canvas is fills/lines only).
11. **Media provider v2 (Windows)**
    - Album art: shim reads the SMTC thumbnail stream, host caches to a
      file, provider exposes `artPath` — rides the existing local-path
      `<image>` with zero new transport.
    - Transport: `media.play/pause/next/previous/seek(ms)` command channel
      back through weaverd. Capability call (Dara to confirm): declared-but-
      quiet under ADR 0002 — Rainmeter-parity, but named in the surface.
    - `status: "playing" | "paused" | "stopped"` replacing the bare bool;
      `sourceApp` so widgets can show which player it is.
12. **Media provider (macOS) — MediaRemote adapter route** (Dara,
    2026-07-21: fine for now, we can do better later). System-wide
    now-playing + transport via the Apple-signed-host adapter approach that
    survives the macOS 15.4 entitlement gate. Known-fragile by design —
    isolate it behind the provider boundary so a future Apple breakage or a
    switch to per-app scripting (Spotify/Music AppleScript) changes nothing
    widget-side. Supersedes ADR 0015's "unavailable". SDK types stay
    platform-honest: art/transport optional, never fabricated.
13. **Gate: noro-player port** in `examples/`, side-by-side screenshot
    against the Rainmeter original on both OSes. Done means a stranger can't
    pick out which is which, and prev/play-pause/next/seek work.

Explicitly not on this list: CSS `absolute`/`inset` positioning (stack covers
the need), scrolling/overflow-scroll (widgets, not documents), grid layout
(flex + stack until a real widget demands it), `z-index` (stack order is
paint order), responsive/media-query variants (widgets own their size),
blend modes (alpha tiles cover texture overlays), scroll-wheel input and
tooltips (revisit if a real widget demands them).
