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

## DPI geometry ownership amendment

The shared renderer protocol's coordinate contract is version 3. The widget
host owns each GPU child's logical destination frame and its once-rounded
physical edges. The renderer owns an exact physical source texture of that edge
difference while continuing to rasterize packet coordinates expressed in DIPs.
DirectComposition targets the actual GPU child HWND, with an explicit physical
clip and identity transform; the child client rectangle owns destination
placement and clipping. Geometry generations invalidate retained dimensions
and force one full repaint only when DPI, logical destination, physical edges,
or renderer connection changes. This prevents implicit compositor defaults or
double scaling from becoming architecture. The full contract and evidence are
recorded in [Windows DPI scaling](../dpi-scaling.md).
