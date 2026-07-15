# Native SDK fork consolidation

Verified 2026-07-14 on Windows with Zig 0.16.0 from
`E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0`.

## Canonical branch

`weaver-main` is the canonical Weaver branch of
[`SunkenInTime/native`](https://github.com/SunkenInTime/native). It is a clean
four-commit series on Native SDK v0.4.4 (`ce3e42df`):

1. `ce9be582` - **Widget capacity profile as a build option** owns the
   `-Dwidget-profile` switch, capacity selection, and profile-aware tests.
2. `f8aa72f8` - **Desktop-widget windowing** owns the Windows desktop-layer,
   anchoring, transparency, activation, and related window behavior.
3. `8d478551` - **Immediate canvas seam and damage-aware software presents**
   owns immediate-canvas submission and dirty-region software presentation.
4. `e5fb695f` - **D3D11 presenter and shared renderer protocol** owns the D3D11
   presenter and the protocol used by Weaver's shared renderer.

The old stacked branches are frozen historical branches. In stack order they
are `weaver-fork`, `weaver-fork-m3`, `weaver-fork-gpu`,
`weaver-fork-renderer`, and `weaver-fork-hybrid`. Do not extend them or use
them as a base for new Weaver work.

## Capacity profiles

`-Dwidget-profile` defaults to `false`. With the option omitted, Native SDK
retains its upstream capacities and stock multi-window/multi-view behavior:

| Capacity | Stock/default | Weaver widget |
|---|---:|---:|
| Windows | 16 | 1 |
| Views | 32 | 1 |
| Webviews | 16 | 1 |
| Canvas commands per view | 2048 | 128 |
| Canvas path elements per view | 2048 | 256 |
| Retained canvas widget nodes per view | 1024 | 128 |

With `-Dwidget-profile=true`, the bounded single-widget values are compiled
in. Tests which require multiple simultaneous views/windows explicitly run in
the stock profile, while behavior and permission tests remain identical in
both profiles. Profile-dependent scratch storage and fixture sizes now follow
the selected capacities. That separation is why the unmodified stock suite
passes when the option is omitted without weakening its behavioral coverage.

Weaver passes the option at both Native SDK build surfaces in
`runtime/build.zig`: the dependency receives `-Dwidget-profile=true`, and the
app artifacts receive `widget_profile = true`. `runtime/src/main.zig` also
contains a compile-time capacity assertion. A Weaver runtime compiled with
stock capacities therefore fails to build; the ReleaseFast success below
proves that the bounded values are present rather than that an unused option
was merely accepted.

The host needs no profile wiring. `host/build.zig.zon` has no Native SDK
dependency, and `weaverd` is a standalone Win32 process that launches and
supervises the runtime. The renderer also has no Zig Native SDK dependency: it
compiles the presenter's C++ source directly. The capacity constants live in
the Zig runtime, so there is no meaningful `-Dwidget-profile` option to pass
to either host or renderer.

## Repository ownership boundary

The four commits are review boundaries inside the Weaver fork, not a queue of
upstream pull requests. The capacity profile, desktop-widget windowing,
damage-aware presenter, and shared-renderer protocol exist for Weaver's product
model and stay owned on `SunkenInTime/native:weaver-main`.

The general Native SDK concern discovered during this work was the Windows
static-TLS memory multiplier in
[vercel-labs/native#114](https://github.com/vercel-labs/native/issues/114).
That concern was fixed upstream separately by Native SDK PR #117. Do not infer
from the clean Weaver commit stack that the remaining product-specific changes
should be proposed upstream.

## Verification

The PowerShell sessions used this setup so Zig 0.16.0 and the POSIX `test`
helper required by Native SDK's validation steps were both available:

```powershell
$zig = 'E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0'
$env:PATH = "$zig;C:\Program Files\Git\usr\bin;$env:PATH"
```

### Native SDK

Run from `runtime/native-sdk`:

| Command | Result |
|---|---|
| `zig build test` | PASS, exit 0, 64.12 s |
| `zig build test -Dwidget-profile=true` | PASS, exit 0, 76.50 s |
| `zig build test-widget-profile -Dwidget-profile=true` | PASS, exit 0, 3.33 s |
| `zig build test-canvas -Dwidget-profile=true` | PASS, exit 0, 36.41 s |
| `zig build test-desktop-runtime-core -Dwidget-profile=true` | PASS, exit 0, 31.13 s |
| `zig build test-desktop-canvas-frame -Dwidget-profile=true` | PASS, exit 0, 14.93 s |
| `zig build test-desktop-platform -Dwidget-profile=true` | PASS, exit 0, 18.39 s |
| `zig build test-desktop-canvas-widget -Dwidget-profile=true` | PASS, exit 0, 15.89 s |
| `zig build test-desktop-ui-shell -Dwidget-profile=true` | PASS, exit 0, 28.28 s |

The repository gate was run from Git Bash with the same Zig directory on
`PATH`:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' scripts/gate.sh fast ce3e42df
```

It passed in 51 seconds: `zig-test` 27 s, `zig-validate` 1 s,
`examples-frontends` 2 s, `examples-native` 17 s, and `examples-mobile` 4 s.
The platform-conditional benchmark, CEF, and docs checks were skipped by the
gate because their relevant files/platform were unchanged. An earlier gate
attempt reached a process-level `bad_alloc` in `examples-native`; rerunning
that target alone passed in 37.05 seconds, and the complete gate then passed
without a code change.

### Weaver

Run from the repository root unless a directory is shown:

| Command | Result |
|---|---|
| `npm test` | PASS, 7/7 tests, exit 0, 2.84 s wall time |
| `npm run typecheck` | PASS, exit 0, 2.63 s |
| `npm run build` | PASS, exit 0, 0.90 s |
| `zig build -Doptimize=ReleaseFast` in `runtime` | PASS, exit 0, 72.09 s |
| `zig build -Doptimize=ReleaseFast` in `host` | PASS, exit 0, 0.55 s |
| `zig build -Doptimize=ReleaseFast` in `renderer` | PASS, exit 0, 0.53 s |

Each Zig command used the `zig.exe` from the path above.

### Host smoke

The smoke used an isolated temporary `LOCALAPPDATA` registry after briefly
pausing an unrelated, pre-existing host singleton:

```powershell
$env:LOCALAPPDATA = "$env:TEMP\weaver-lane-a-smoke-53588"
node cli\dist\index.js install examples\clock
node cli\dist\index.js install examples\visualizer
node cli\dist\index.js status --json
```

- Clock visibly rendered its time/date card in a 240 x 110 window. Host
  status reported the Clock runtime `running` with backend `software`.
- Visualizer visibly rendered its `SPECTRUM` card and live bars in a 288 x 110
  window while `C:\Windows\Media\Alarm01.wav` supplied a deterministic audio
  signal. Host status reported `audioSilent: false`, the Visualizer runtime
  `running` with backend `gpu`, and the shared renderer `running` with backend
  `gpu`.

The screenshots were captured through the in-app desktop inspector. The
temporary host was stopped with `node cli\dist\index.js down`, its audio
helper and registry directory were removed, and process inspection confirmed
zero `weaverd`, `weaver-widget`, or `weaver-renderer` processes from this
worktree. The unrelated Pomodoro session was then restored from its original
worktree.

## Remaining limitations and risks

- Verification and smoke coverage here are Windows-only.
- The high-DPI Visualizer strip found during consolidation is resolved by the
  protocol-v3 explicit source/destination geometry contract and child-HWND
  DirectComposition ownership. GPU and software captures pass every edge at
  100%, 125%, 150%, 175%, and 200%; see
  [Windows DPI scaling](dpi-scaling.md).
- Native SDK's Windows validation scripts require Git's POSIX `test.exe` on
  `PATH`; without it, the full suite fails before reaching implementation
  assertions.
- The historical remote branches are documented as frozen but were not
  deleted or server-protected by this local consolidation.
