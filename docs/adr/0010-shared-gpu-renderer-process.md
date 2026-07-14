# GPU rendering centralizes in one shared renderer process

M3c proved per-process GPU rendering is CPU-cheap but memory-expensive: the
D3D driver charges every process ~71 MB private WS and ~65 threads. Decision:
weaverd supervises a single `weaver-renderer` process (spawned only while at
least one GPU widget runs) that owns the one D3D device and rasterizes every
GPU widget's command stream into per-widget shared composition surfaces;
widget processes remain isolated logic processes and never load D3D. Accepted
sacrifice, per Dara 2026-07-14: a renderer crash blanks all GPU widgets for a
beat (weaverd restarts it; widgets fall back to software until it returns)
instead of one — the browser-compositor tradeoff. Cost accounting stays
honest: the renderer appears as its own row in `weaver status`. Rejected:
per-process D3D (memory doesn't scale past one GPU widget) and moving widget
logic into the renderer (destroys the crash-isolation and capability model
that process-per-widget provides).
