# M0 results: `weaver-widget`

M0 is a single Windows executable that embeds QuickJS-NG, evaluates a widget's
plain-JavaScript bundle on the Native SDK main thread, and derives an SDK builder
view from the bounded retained tree described in ADR 0009. The proof widget is
[`examples/clock`](../examples/clock); the desktop capture is
[`m0-clock.png`](m0-clock.png).

## Build from a clean checkout

Prerequisites:

- Windows 11.
- Zig 0.16.0 at
  `E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0\zig.exe`.
- `E:\Projects\native` checked out at branch `weaver-fork`. M0 deliberately
  uses a path dependency; the SDK is not copied into this repository.

From the Weaver repository root in PowerShell:

```powershell
git clean -xfd
git -C E:\Projects\native switch weaver-fork
New-Item -ItemType Junction -Path runtime\.native-sdk -Target E:\Projects\native
$env:PATH = 'E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0;' + $env:PATH
Push-Location runtime
zig build -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off
zig build test -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off
Pop-Location
```

Run from the repository root:

```powershell
runtime\zig-out\bin\weaver-widget.exe examples\clock
```

The ignored `runtime/.native-sdk` junction makes the dependency location
explicit and keeps machine-specific absolute paths out of `build.zig.zon`.
Local M0 verification used the read-only Native worktree at
`C:\Users\shawn\.codex\worktrees\codex-run-42124-871936`, commit
`71df7a38`, because `E:\Projects\native` was checked out on `main`; the
`weaver-fork` ref points to that exact commit.

QuickJS-NG `v0.15.1` is vendored at commit
`fd0a0210b7be00957751871e7e01b8291268fc29`. Only the four core engine C
translation units are compiled; `quickjs-libc` and its OS/std modules are not.

## What the proof exercises

- The strict JSON manifest supplies name, 240 x 110 size, top-right work-area
  anchor, desktop layer, and transparency.
- The SDK manifest predeclares the startup-only Win32 chrome: chromeless,
  layered/premultiplied, bottom, and no-activate. The runtime manifest supplies
  the matching dynamic scene and initial frame.
- JavaScript creates `panel`, `column`, `row`, and `text` nodes only through the
  `native` bridge, then changes the two clock text nodes from the SDK's repeating
  effect timer.
- The retained tree has fixed limits (128 nodes, 24 children per node, 192 text
  bytes per node). An effective op increments its generation; there is no
  markup interpreter, browser, JS worker, polling timer, or continuous render
  loop.
- `Shell.Application.MinimizeAll()` left the widget visible during proof capture.
  Its rounded transparent corners expose the wallpaper, and normal windows
  cover it because the fork enforces the bottom layer.

Two screen captures taken more than three seconds apart showed `:16` and `:20`.
The latter is the committed proof image.

## ReleaseFast measurement

Measured after settling, on the clock proof process. CPU is the
`TotalProcessorTime` delta over 15.011 seconds; “one core” is the useful widget
billing number, while machine-normalized uses all 16 logical processors.

| Metric | Result |
|---|---:|
| Executable size | 6,281,216 bytes (5.99 MiB) |
| Total working set | 31,449,088 bytes (29.99 MiB) |
| Private working set (`WorkingSetPrivate`) | 12,832,768 bytes (12.24 MiB) |
| Private bytes | 21,254,144 bytes (20.27 MiB) |
| Threads | 7 |
| CPU time over 15.011 s | 0.125 s |
| CPU, one-core normalized | 0.83% |
| CPU, 16-core machine normalized | 0.052% |
| Requested JS timer cadence | 1.00 Hz |
| Observed Native presents | about 2.00 Hz (10 frames / 4.99 s) |

The 1 Hz callback is event-driven and idle between ticks, but UiApp currently
presents roughly twice per changed clock tree. This is still idle-zero-ish—not a
60 fps loop—but M1 should identify whether the second frame is the layout
correction retry or the Windows layered-present path and remove it where safe.

## Honest M0 caveats

- Startup window chrome is compile-time Native SDK manifest state. The runtime
  JSON can position and name this one desktop-widget class, but M0 intentionally
  rejects opaque or non-desktop manifests rather than pretending arbitrary
  per-widget chrome is dynamic.
- Anchor math uses the primary Win32 work area. Multi-monitor selection and a
  physical-pixel versus per-monitor-DPI audit remain follow-up work.
- QuickJS runs on the UI thread and has neither a memory limit nor an interrupt
  deadline yet. A malicious or accidental infinite loop can hang the widget;
  process isolation limits the blast radius but does not make that acceptable.
- The M0 bridge supports only the properties listed in the milestone and uses
  `#RRGGBBAA` for its RGBA value. There is no TSX compiler, reconciler, input
  event surface, module loader, persistence, or hot reload yet.
- QuickJS-NG's core locale support rendered the example date numerically on the
  verification machine even though the bundle requested weekday/month labels.
  The clock and date remain JS-derived; richer locale data is a packaging choice.
