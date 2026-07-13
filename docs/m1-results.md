# M1 results: the conjure loop

M1 closes the source-to-desktop loop described by `sdk/CONTRACT.md`:

```text
weaver init -> edit widget.tsx -> weaver check -> weaver bundle/dev
            -> QuickJS reconciler -> retained-tree ops -> Native desktop window
```

The proof image is [`m1-clock.png`](m1-clock.png). It came from the scaffolded
clock after `weaver dev`, then a watched source edit changed the card from the
starter charcoal to purple and restarted the runtime.

## Build from a clean checkout

Requirements:

- Windows 11.
- Node.js 20.11 or newer. Verification used Node 26.4.0 and npm 11.17.0.
- Zig 0.16.0 at
  `E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0\zig.exe`.
- `E:\Projects\native` on `weaver-fork` (`71df7a38`). It is a read-only path
  dependency, not copied into Weaver.

From the repository root in PowerShell:

```powershell
git clean -xfd
git -C E:\Projects\native switch weaver-fork
if (-not (Test-Path runtime\.native-sdk)) {
    New-Item -ItemType Junction -Path runtime\.native-sdk -Target E:\Projects\native
}
$env:PATH = 'E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0;' + $env:PATH
npm install
npm test
npm run typecheck
Push-Location runtime
zig build -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off
zig build test -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off
Pop-Location
```

`npm install` links both workspaces and its postinstall builds
`cli/dist/index.js`, including the `node_modules/.bin/weaver` command. The SDK
has zero runtime dependencies; esbuild and TypeScript are CLI/tooling
dependencies.

## Mechanical conjure gate

From the repository root:

```powershell
New-Item -ItemType Directory examples-scratch
Set-Location examples-scratch
npx --no-install weaver init myclock
npx --no-install weaver check myclock
npx --no-install weaver dev myclock
```

The generated `widget.tsx` is the frozen-contract clock using
`useProvider("time")` and `subscribe: ["time"]`. `bundle`/`dev` emit and run
`myclock/dist/bundle.js` plus `myclock/dist/widget.json`; the Native runtime's
argument remains a dumb directory containing exactly those two artifacts.

The watched background edit changed `bg-[#11141c]/86` to
`bg-[#4c1d95]/86`. The widget PID changed from 43140 to 37984 and the next
2-second poll already contained `weaver dev restarted widget`, satisfying the
under-3-second restart gate.

The required broken-widget check returned one block and exit code 1:

```text
weaver failed (3 errors)
- widget.tsx: Unknown class utility "pad-13". Did you mean "p-[13px]"?
- widget.tsx: <button> arrives in M2
- useProvider("time") requires subscribe: ["time"] in the widget config
```

Source locations include absolute path, line, and column in the real output.
M2/M3 intrinsics remain present in `@weaver/sdk`'s declarations but are refused
statically; unsupported classes are never runtime no-ops.

## What closed

- `@weaver/sdk`: automatic JSX runtime, dependency-free keyed reconciler,
  component hooks, native-clocked intervals, lazy `time` provider, fixed class
  compiler, public declarations including scheduled elements, and literal
  `widget(config, component)` entry.
- Native bridge: `insertBefore`, 16 concurrent keyed timers, render batch
  boundaries, the M1 style/layout properties, full anchor/layer manifest
  parsing, a 32 MiB QuickJS memory limit, and a 100 ms per-turn interrupt.
- CLI: strict scaffold, `tsc --noEmit` plus AST validation, esbuild IIFE and
  manifest extraction, external-import wall, restart-on-save dev loop, and
  single-block failures.
- Conjure skill: the workflow, complete M1 class table, and loud provider,
  input, network, and capability boundaries inline.

The interrupt floor was exercised with `while (true) {}`. The runtime exited
with `InternalError: interrupted` in 170 ms instead of hanging.

## ReleaseFast full-pipeline measurement

Measured on the purple scaffolded clock after settling. CPU is the process
`TotalProcessorTime` delta over 15.013 seconds. Private working set is the
`WorkingSetPrivate` performance counter.

| Metric | Result |
|---|---:|
| Runtime executable | 6,303,232 bytes (6.01 MiB) |
| Bundled widget IIFE | 9,393 bytes |
| Total working set | 32,952,320 bytes (31.43 MiB) |
| Private working set | 14,172,160 bytes (13.52 MiB) |
| Private bytes | 22,622,208 bytes (21.57 MiB) |
| Threads | 9 |
| CPU time over 15.013 s | 0.046875 s |
| CPU, one-core normalized | 0.312% |
| CPU, 16-core machine normalized | 0.0195% |
| Time-provider callbacks | 1.00 Hz |
| Rendered presents | 1.00 Hz (10 revision edges over 9.004 s) |

### M0 double-present finding

The SDK fork emits one frame event to render a requested retained-canvas
revision and a second event when that present completes. M0's logger counted
both callbacks as presents. The completion carries the same `canvas_revision`
and does not render again. M1 counts revision edges and measures one actual
rendered present per 1 Hz clock update, so there was no runtime/bridge
double-present bug to fix.

Every JavaScript render is bracketed by private `beginBatch`/`endBatch` bridge
ops. All effective tree mutations in that render advance the native generation
once; the live clock log advanced generation 11, 21, 31 while reporting 10, 20,
30 callbacks.

## Honest caveats

- The fork exposes regular/medium/bold text spans. M1 maps `font-light` to
  regular and `font-semibold` to bold. It also lacks baseline cross alignment,
  so `items-baseline` maps to end alignment. Both retain honest layout rather
  than silently dropping the utility; native font/baseline fidelity is follow-up.
- Native row/column nodes are layout-only. The runtime wraps a styled row or
  column in the SDK's painting panel while preserving its inner flex layout.
- `UiApp` still rebuilds after any delivered timer Msg. A `useInterval` callback
  that intentionally makes no state/tree change therefore crosses the builder
  once, although batching leaves the retained generation unchanged. The time
  provider changes once per tick and remains strictly idle between ticks.
- `origins` is statically parsed and validated, but no network API is exposed in
  M1. Input elements, canvas, capabilities, and every M2+ class family fail at
  check time as specified.
- Dev uses process restart, so widget state resets on every source save. True
  hot swap remains M2.
