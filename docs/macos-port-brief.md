# macOS port brief (Lane D)

For the agent session that runs this on the MacBook. Weaver context: read
README.md, sdk/CONTRACT.md, docs/adr/ (esp. 0006, 0007, 0008, 0010),
docs/ROADMAP.md. Prereq: Lane A (fork consolidation) merged — the fork's
`weaver-main` branch with `-Dwidget-profile` is the base; do NOT start this
port against the old stacked branches.

## What already exists on macOS (upstream Native SDK)
The strongest platform: Metal presentation, native menus/tray/dialogs, the
software reference renderer, IME. The fork's Windows-specific work
(ULW/DComp/WorkerW) does not apply; macOS needs its own equivalents.

## Workstreams, in order

1. **Toolchain + baseline** — Zig 0.16.0 on macOS, clone weaver with
   submodule, build runtime/host/renderer (renderer will need a Metal or
   stub path — see 4), run the stock counter/clock to prove the substrate.
2. **Desktop-widget windowing** — the macOS analogues of the ShellWindow
   fields: `transparent` (NSWindow isOpaque=false + clear backgroundColor),
   `layer=desktop` (NSWindow level `kCGDesktopWindowLevel`/behind, plus
   collectionBehavior `.stationary | .canJoinAllSpaces | .ignoresCycle` so
   Mission Control/Show Desktop leave it alone — VERIFY each behavior, the
   Windows port found surprises here), `click_through`
   (ignoresMouseEvents), `no_activate` (nonactivating panel style or
   NSPanel). Chromeless = borderless style mask.
3. **Providers** — cpu/memory via host_statistics64/vm_statistics; media via
   MPNowPlayingInfoCenter/MediaRemote (private-ish API — evaluate what's
   shippable; SMTC equivalent is murkier on macOS, document honestly);
   audio loopback via ScreenCaptureKit audio capture (13+) or an
   aggregate-device tap — this is the hard one, spike it early.
4. **Renderer** — decide: Metal presenter in weaver-renderer (upstream fork
   already has Metal machinery), or software-only for macOS v1 with the
   shared-renderer seam stubbed. Software-first is acceptable; the M3a
   damage-aware path is cross-platform Zig.
5. **Gate** (mirror the Windows gates): clock <=15 MiB private / ~0% idle;
   mixed visualizer with live audio; Show-Desktop/Mission Control survival;
   `weaver dev` hot-swap working; all suites green on macOS CI runner.

## Ground rules
Same as Windows lanes: fork changes on a branch, measured claims only,
results doc per milestone (docs/macos-mN-results.md), no pushes without
review. The platform seam rule from ADR 0006 is absolute: nothing
macOS-specific leaks into the SDK contract.
