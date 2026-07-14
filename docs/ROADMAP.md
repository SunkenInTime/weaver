# Roadmap

Ordering set by Dara, 2026-07-15. Current state: M0–M4a merged (conjure loop,
host, providers, interactive elements, shared GPU renderer); M4b (hybrid
retained-texture layer, fps=0 idle, source-missing status) in flight.

1. **Fork consolidation** — consolidate the stacked fork branches into one
   clean `weaver-main` lineage; make the widget capacity profile a build option
   so stock fork tests pass; prepare the upstream PRs (TLS fix / #114, widget
   windowing fields, damage-aware presenter) while rebasing is cheap.
2. **Dev polish** — state-preserving hot-swap for `weaver dev`, `weaver logs
   <widget>`, multi-monitor anchoring + per-monitor DPI audit, better errors.
3. **`weaver pack` / `weaver install`** — the `.weave` file: zipped widget
   source + lineage (source-is-the-artifact, ADR 0004). Includes the
   capability consent UI (the loud wall from ADR 0002 gets its actual dialog)
   and the first real implementations of gated capabilities.
4. **`weaver remix`** — copy an installed widget's source to an editable
   folder, bump lineage, hand to your agent. Conjure skill v2 covering the
   full API surface.
5. **The manager + API breadth** — weaverd tray + widget-list/cost/permission
   surface (candidate: first Weaver app built with Weaver). Remote images,
   canvas gradients/paths, media control, network/battery providers.
6. **macOS** — desktop-layer windowing semantics, MPNowPlaying/CoreAudio
   provider shims, Mac CI. The platform seam pays rent.
7. **Gallery** — hosted browse / one-click install / remix lineage /
   capability badges.
8. **Packaging** — installer/winget bundle (weaverd, renderer, runtime, CLI,
   esbuild), weaverd login auto-start. Built last by design; note: it gates
   the gallery's public launch, since gallery users need an install story.

Not on the roadmap: GPU text atlases (until profiling demands), JSX sugar
layer (TSX won), web embedding (cut), Linux (acknowledged, unloved — ADR 0006).
