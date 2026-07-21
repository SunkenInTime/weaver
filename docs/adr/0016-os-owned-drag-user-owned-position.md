# Widgets drag by their whole surface through the OS; the dragged position is user state that outranks the anchor

Every Widget window is repositionable by grabbing anywhere on its visible
surface, with no developer opt-in and no SDK surface. The retained root node
becomes one Native SDK `window_drag` region; press-claiming widgets inside it
(buttons, sliders) turn into exclusion rects automatically, so their
interactions win over the drag. The gesture itself is OS-owned end to end —
macOS hands the live mouse-down to `performWindowDragWithEvent:`, Windows
answers `WM_NCHITTEST` with `HTCAPTION` inside mirrored drag regions — so a
drag costs what dragging any native titlebar costs: zero bridge traffic, zero
JS, zero widget re-render. Parked Metal surfaces stay parked and the shared
D3D renderer never re-rasterizes; the window server just moves the layer.

The resulting position is user state, not Widget source (ADR 0004, ADR 0011):
it never rewrites the installed manifest and never enters the Widget's
JS-visible storage document. The runtime observes the substrate's
`window_frame_changed` reports through a new `on_window_frame` app hook,
debounces the continuous per-move stream behind one replaceable one-shot
timer, and writes a small per-Widget JSON record
(`<data-root>/geometry/<name-hash>.json`, atomic write-rename). At launch a
valid record outranks the manifest anchor; the anchor remains the placement
until the first real drag, resumes if the record is deleted, and resumes when
the record goes stale (Windows validates a grabbable corner against the
virtual desktop; macOS clamps to the primary visible frame in AppKit at
creation). A locked/undraggable mode is planned and will layer on this as a
policy bit, not a new mechanism.

Rejected: streaming pointer deltas to JS and repositioning per frame — worse
latency, CPU per move tick, and it fights surface parking. Rejected: the
substrate's built-in window-state store (`windows.zon`), which writes on every
move tick and is keyed by bundle id, so every Widget process would race a
read-merge-write on one shared file; Weaver turns it off
(`persist_window_state = false`) and owns a per-Widget record instead.
Rejected: persisting through the Widget's `useStorage` quota — placement is
the user's, and Widget code must not be able to read or clobber it. Rejected:
a drag-handle or `draggable` SDK prop for now — the whole surface is the
obvious handle; an escape hatch can be added if a real Widget needs one.
