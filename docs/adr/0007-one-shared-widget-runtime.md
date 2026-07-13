# One shared widget-runtime exe; widgets are source bundles, never binaries

Weaver ships a single `weaver-widget` runtime executable (JS engine +
renderer + windowing). The host spawns one process of it per widget — crash
isolation preserved — and each instance loads that widget's esbuild-bundled
JS. Widgets themselves are only source folders (ADR 0004); install/conjure/
remix never invoke a native toolchain, keeping the Loop's iteration
sub-second. Because all widget processes run the same image, the OS shares
its code pages: marginal cost of each additional widget is roughly JS heap +
framebuffer. Rejected: per-widget native compilation (the substrate's default
model) — it puts a compiler between the user and every conjure/remix, and
duplicates the runtime in every binary. Trade-off accepted: widget logic runs
as interpreted JS; the rendering hot path remains native inside the runtime.
