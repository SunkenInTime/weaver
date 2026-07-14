# M2a results: interactive widgets, wfetch, and storage

M2a turns on the widget-facing part of the v0.2 contract without introducing
`weaverd`. The proof widget is [`../examples/pomodoro/widget.tsx`](../examples/pomodoro/widget.tsx),
and the desktop capture is [`m2a-pomodoro.png`](m2a-pomodoro.png).

## Build and check

Requirements are unchanged from M1: Node.js 20.11+, npm, Zig 0.16.0 at
`E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0`, and the pinned
`runtime/native-sdk` submodule at `71df7a38`.

```powershell
git submodule update --init --recursive
$env:PATH = 'E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0;' + $env:PATH
npm install
npm test
npm run typecheck
Push-Location runtime
zig build -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off
zig build test -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off
Pop-Location
node cli\dist\index.js check examples\pomodoro
node cli\dist\index.js bundle examples\pomodoro
node cli\dist\index.js dev examples\pomodoro
```

`weaver bundle` now makes `dist` self-contained: regular widget-owned files
are copied recursively while `widget.tsx`, `tsconfig.json`, and `dist` are
excluded. This is why `./assets/foo.png` means the same thing during `dev` and
after a future install.

## What closed

### Interactive retained nodes

- `button`, `slider`, and `image` are real retained node kinds. The SDK keeps
  handler functions in one JS map and registers one native event dispatcher;
  native nodes retain only press/change presence bits.
- Buttons use the fork's pressable panel behavior, preserving arbitrary child
  layout and the existing class styling surface.
- Sliders use the fork's real slider. Click-set and every drag move route the
  applied native fraction back to the owning node id, then the runtime scales
  it to the contract's `value/max` range.
- Image paths must be relative, cannot traverse with `..`, and cannot be URL
  schemes. PNG bytes are decoded and registered in `init_fx` before the first
  view build.

### `wfetch`

- WinHTTP is the Windows TLS implementation. Four request workers may run at
  once; QuickJS is touched only when the Native main loop drains a completed
  slot. Request buffers and the worker timer exist only while a request is
  active, so the network capability adds no fixed multi-megabyte allocation
  to an idle widget.
- Runtime policy is authoritative: HTTPS only, case-insensitive exact host
  match against manifest `origins`, a whole-exchange 15 second deadline,
  5 MiB response cap, and no cookies shared between requests.
- Automatic redirects are disabled. This is stricter than merely blocking
  cross-host redirects: a same-host 3xx is returned to the widget instead of
  followed, guaranteeing that WinHTTP cannot cross the declared boundary.
- The SDK exposes both imported and global `wfetch`, with `status`, `ok`,
  `text()`, and `json()`.

### `useStorage`

- The SDK loads one JSON object at startup, namespaces values by hook key,
  checks UTF-8 size before accepting a setter, and debounces writes for 200 ms.
- Native code rechecks the exact 64 KiB quota and atomically writes through a
  sibling temporary file to
  `%LOCALAPPDATA%\weaver\storage\<widget-name-hash>.json`.
- A normal runtime teardown calls the SDK's final synchronous flush hook.
  Windows `TerminateProcess` cannot run teardown, so `weaver dev` force-kills
  rely on the already-completed 200 ms debounce.

### M2b seam

`cpu` and `memory` are present in public provider types and subscribe
validation. Calling either with a declared subscription currently throws
`Provider "<name>" requires weaverd; run "weaver up"`. The branch is marked
`TODO(M2b)`; no host, supervision, provider polling, or cost accounting was
added in M2a.

## Mechanical proof

The ReleaseFast automation build used the fork's own retained-widget commands:

```text
native automate widget-click widget-canvas 9433737043790503074
native automate widget-drag widget-canvas 18394575625175258233 0.42 0.75
```

- Start changed `25:00` to `24:57` and the button label to `Pause`.
- Pausing and dragging changed the native slider from `0.4167` to `0.75`, the
  setting from 25 to 45 minutes, and the clock to `45:00`.
- After the 200 ms debounce, storage contained
  `{"timer":{"minutes":45,"remaining":2700,"running":false}}`.
- Killing both dev/runtime processes and relaunching restored `45:00`,
  `45 min`, and slider value `0.75`. A later watched source edit restarted the
  process and preserved the same state, proving the `weaver dev` case too.
- A separate 32x32 PNG probe bundled `dist/assets/probe.png`, produced a native
  `role=image` node, and sampled the image color from the rendered surface.

WorldTimeAPI reset its connection during preflight, so the live network proof
used `https://httpbin.org/json` (HTTP 200). With `origins: ["httpbin.org"]`,
the rendered result was `Sample Slide Show`. A literal undeclared call failed
at check time with:

```text
OriginNotDeclared: add "httpbin.org" to origins in your widget config
```

The same URL assembled dynamically passed static checking and rendered that
exact rejection from the runtime when `origins` was empty. `<canvas>` still
failed with `<canvas> arrives in M3`.

## Measurements

Windows 11, ReleaseFast, 320x210 transparent desktop-layer pomodoro. CPU is
`TotalProcessorTime` delta over 15 seconds expressed as percent of one core.
These are final production measurements without `-Dautomation=true`; the
automation build was used only for the interaction proof above.

| Build/state | Private WS | Total WS | Private bytes | Threads | CPU / one core |
|---|---:|---:|---:|---:|---:|
| Production, paused | 9.59 MiB | 27.90 MiB | 17.73 MiB | 4 | 0.52% |
| Production, running | 9.66 MiB | 28.03 MiB | 17.79 MiB | 4 | 0.62% |

The production binary is 6,397,952 bytes (6.10 MiB). The running state adds
about 68 KiB of private working set and 0.10 percentage points of one-core CPU
in this sample; both figures are small enough that normal Windows scheduling
and working-set trimming remain relevant noise.

## Honest caveats

- The pomodoro keeps `useInterval(1000)` mounted while paused. Its callback
  makes no retained ops, but the fork still rebuilds/presents after every
  delivered no-op timer Msg. Paused is therefore about one present per second,
  not idle-zero. Fixing that cleanly needs a cancellable/disabled interval
  authoring shape or a fork change that skips rebuild when generation is
  unchanged.
- Native's current registered-image profile permits 16 images and 256 KiB of
  decoded RGBA pixels per image. Larger PNGs fail loudly at registration.
- WinHTTP workers are joined during orderly teardown and may wait for the
  remaining portion of the 15 second deadline. Force-kill remains immediate.
- Same-host redirects are surfaced as 3xx rather than followed, as noted
  above. Cookies are not persisted because every request owns a new WinHTTP
  session.
