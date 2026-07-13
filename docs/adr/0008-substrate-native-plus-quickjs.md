# Substrate: Native SDK fork + embedded QuickJS-NG, confirmed after re-audit

The July 2026 re-audit measured the new load profile (TSX authoring, 30-60fps
visualizers) against the Native SDK substrate: QuickJS-NG adds only ~0.6 MiB
private WS and ~16 ms cold start; a projected TSX clock is ~11.6 MiB / 0.7%
CPU and even a 480x320 visualizer stays under 15 MiB — the <20 MiB posture
holds with headroom. The one real gap is the software render path: ~36-39fps
achieved when 60 requested, at 12-30% CPU, dominated by full-frame software
rendering (not the layered-window present). Decision: Native stays; the GPU/
dirty-region render workstream becomes milestone M3 rather than grounds for
switching. Rejected alternative: Rust assembly (Taffy/Parley/Vello) — it
would buy the GPU path sooner but re-spend months on windowing/text maturity
the fork has already proven (transparent desktop-layer windows, Win+D
survival, 11 MiB processes). Measurements: E:\Projects\native-spike\RESULTS.md.
