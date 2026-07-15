# Roadmap

Ordering set by Dara, 2026-07-15. Current state: M0–M4b, fork consolidation,
dev hot-swap/logs, and the Windows per-monitor DPI contract are complete. The
portable `.weave` pack/install boundary is implemented; capability grants are
the next trust-boundary work.

1. **Fork consolidation — complete** — consolidate the stacked fork branches into one
   clean `weaver-main` lineage; make the widget capacity profile a build option
   so stock fork tests pass. The general TLS problem from #114 was upstreamed;
   Weaver's capacity, widget-windowing, and presenter changes remain fork-owned
   because they serve Weaver rather than Native SDK's product surface.
2. **Dev polish — complete** — state-preserving hot-swap for `weaver dev`, `weaver logs
   <widget>`, better errors. Multi-monitor anchoring and the per-monitor DPI
   audit are complete; see [Windows DPI scaling](dpi-scaling.md).
3. **`weaver pack` / `weaver install` — artifact complete, grants next** — the
   `.weave` file is deterministic zipped source + declared surface + lineage
   (source-is-the-artifact, ADR 0004). Install validates and builds a
   Weaver-owned copy, audits quiet capabilities, and never registers the
   sender's workspace. Next: the loud capability consent UI from ADR 0002 and
   the first real gated capability.
4. **`weaver remix`** — copy an installed widget's source to an editable
   folder, bump lineage, hand to your agent. Conjure skill v2 covering the
   full API surface.
5. **The manager + API breadth** — weaverd tray + widget-list/cost/permission
   surface (candidate: first Weaver app built with Weaver). Remote images,
   canvas gradients/paths, media control, network/battery providers.
6. **[macOS](macos-port-brief.md)** — performance-native AppKit windowing, a
   measured software/Metal architecture, provider shims, and Mac CI. The
   platform seam pays rent.
7. **Gallery** — hosted browse / one-click install / remix lineage /
   capability badges.
8. **Packaging** — installer/winget bundle (weaverd, renderer, runtime, CLI,
   esbuild), weaverd login auto-start. Built last by design; note: it gates
   the gallery's public launch, since gallery users need an install story.

Not on the roadmap: GPU text atlases (until profiling demands), JSX sugar
layer (TSX won), web embedding (cut), Linux (acknowledged, unloved — ADR 0006).
