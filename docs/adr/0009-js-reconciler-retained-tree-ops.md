# The reconciler runs in JS; the boundary carries retained-tree mutation ops

Each widget's Preact-class VDOM reconciler runs inside its QuickJS context.
What crosses the JS→native boundary is minimal mutation operations against a
retained native tree (create node, set prop, remove, reorder) — never full
re-renders. This makes idle-zero (ADR 0005) structural: no state change → no
ops → no repaint. The <canvas> element is the deliberate exception: an
immediate-mode per-frame draw-command buffer for visualizers and graphs,
driven by the native frame clock. Rejected: shipping a full frame description
per render (repaint traffic proportional to tree size, idle-zero becomes a
diffing heuristic instead of a guarantee) and running the reconciler in
native code (drags VDOM semantics across the language boundary where agents
and the SDK can't see them).
