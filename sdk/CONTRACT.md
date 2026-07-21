# @weaver/sdk — public API contract (v0.2 — M1 surface + the M2 amendment at the end)

This is the authoring contract for Weaver widgets. It is the product's face:
agents learn Weaver from this file. Implementation must match it exactly;
anything not implementable in M1 must fail at `weaver check` with a clear
"arrives in M2" message — never silently no-op.

Design invariants (from ADRs 0001/0003/0005/0009):
- One TSX module per widget; `widget()` is the default export.
- Styling is Tailwind-shaped `class` strings; arbitrary values allowed;
  unknown utilities are check-time errors with fix-its.
- Idle-zero: no state change → no ops → no repaint. The SDK never polls.
- The reconciler runs in JS and emits retained-tree ops (never full frames).

## Module shape

```tsx
import { widget, useProvider, useState } from "@weaver/sdk";

export default widget({
  name: "Clock",
  size: [240, 110],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => {
  const time = useProvider("time");
  return (
    <column class="p-4 gap-1 bg-[#11141c]/86 rounded-2xl">
      <row class="items-baseline gap-2">
        <text class="text-3xl font-light">{time.hh}:{time.mm}</text>
        <text class="text-sm opacity-70">{time.ss}</text>
      </row>
      <text class="text-xs opacity-60">{time.weekday}, {time.month} {time.day}</text>
    </column>
  );
});
```

## `widget(config, component)`

```ts
export function widget(config: WidgetConfig, component: () => JSX.Element): WidgetModule;

export interface WidgetConfig {
  name: string;
  size: [width: number, height: number];          // logical px
  anchor?: {
    monitor?: "primary";                          // M1: primary only
    corner: "top-left" | "top-right" | "bottom-left" | "bottom-right";
    offset?: [x: number, y: number];              // default [24, 24]
  };
  layer?: "desktop" | "normal" | "topmost";       // default "desktop"
  clickThrough?: boolean;                         // default false
  subscribe?: ("time")[];                         // M1: "time" only; full list M2
  origins?: string[];                             // declared API hosts; M1: parsed+validated, fetch arrives M2
  capabilities?: never[];                         // M1: must be empty; ladder arrives M2
}
```

`weaver check` validates config statically (it is extracted from the default
export at bundle time; config must be a literal object — no computed values).

`anchor` is the widget's placement until the user drags it. Every widget is
draggable by its whole surface (buttons and sliders keep their interactions);
the dragged position is user state stored outside the widget — it survives
restarts and reinstalls, outranks `anchor`, and falls back to `anchor` when it
goes stale (e.g. its monitor was unplugged). Widget code cannot read or write
it (ADR 0016).

## Hooks

```ts
export function useState<T>(initial: T | (() => T)): [T, (next: T | ((prev: T) => T)) => void];
export function useRef<T>(initial: T): { current: T };
export function useEffect(fn: () => void | (() => void), deps?: unknown[]): void;
export function useInterval(fn: () => void, ms: number): void;   // native-clocked, auto-cleaned
export function useProvider(name: "time"): TimeData;             // M1: "time" only

export interface TimeData {   // updates once per second while subscribed
  hh: string; mm: string; ss: string;             // zero-padded locale-agnostic
  weekday: string; month: string;                 // short names ("Sun", "Jul")
  day: number; year: number;
  epochMs: number;
}
```

Rules: hooks follow React's rules (top level, stable order). `useProvider`
requires the provider in `config.subscribe` — checked at `weaver check`,
error: `useProvider("time") requires subscribe: ["time"] in the widget config`.

## Hot swap
`weaver dev` evaluates a valid changed bundle in a fresh JS context before replacing the running one.
Root hook slots are seeded by position when slot kind and value type all match; refs keep `current`, while effects restart.
Any slot-count, kind, or type mismatch remounts every root hook; non-serializable values alone initialize fresh.
Evaluation failure leaves the prior context, window, and state running; window-config changes restart the process.

## Elements (JSX intrinsics)

| Element | M1 renders | Props beyond `class`/`children` |
|---|---|---|
| `<column>` | yes | — |
| `<row>` | yes | — |
| `<panel>` | yes | — (a styled box; column layout) |
| `<text>` | yes | — (children: strings/numbers only) |
| `<image>` | check-error "arrives in M2" | `src` |
| `<button>` | check-error "arrives in M2" | `onPress` |
| `<slider>` | check-error "arrives in M2" | `value` `max` `onChange` |
| `<canvas>` | check-error "arrives in M3" | `onFrame(draw, fps)` |

Declared now, implemented on schedule — agents get correct types today and a
loud, dated refusal instead of a silent nothing.

## `class` utilities (M1 set)

Tailwind semantics and scale (1 unit = 4px). Arbitrary values in brackets.
Anything not in this table is a check-time error naming the nearest supported
utility.

| Utility | Maps to |
|---|---|
| `p-N`, `p-[Npx]` | uniform padding |
| `gap-N`, `gap-[Npx]` | flex gap |
| `rounded`, `rounded-{md,lg,xl,2xl,3xl,full}`, `rounded-[Npx]` | corner radius |
| `bg-[#rgb/#rrggbb/#rrggbbaa]`, optional `/NN` alpha suffix | background color |
| `text-[#…]` | text color |
| `text-{xs,sm,base,lg,xl,2xl,3xl,4xl}` | font scale |
| `font-{light,normal,medium,semibold,bold}` | font weight |
| `opacity-NN` | node opacity |
| `items-{start,center,end,baseline}` | cross-axis align |
| `justify-{start,center,end,between}` | main-axis align |
| `grow` | flex grow 1 |
| `w-N`, `w-[Npx]`, `h-N`, `h-[Npx]` | fixed size |
| `truncate` | single-line ellipsis (text only) |

Deliberately absent in M1 (check-error, "arrives M2+"): `px-/py-` split
padding, borders, shadows, gradients, hover/state variants, transitions.

## CLI

```
weaver init <name>       scaffold: <name>/widget.tsx (working starter clock) + tsconfig
weaver check <dir>       tsc --noEmit + config/class/subscribe validation; agent-readable errors
weaver dev <dir>         bundle → run in weaver-widget.exe → watch → rebundle+restart on change
weaver bundle <dir>      esbuild → dist/bundle.js (local output; install rebuilds an owned copy)
```

`weaver dev` restart-on-change is acceptable for M1 (state loss OK); true
hot-swap is M2. All CLI errors must be single-block, copy-pastable, and
actionable — the primary reader is an agent in a fix-it loop.

## The conjure skill

`skills/conjure-widget/SKILL.md` in this repo: teaches an agent to go from a
user's description to `weaver init` → edit widget.tsx → `weaver check` →
`weaver dev`, including this contract inline or by reference, the class table,
and the M1 boundaries (no providers beyond time, no input elements yet).

## v0 done-condition (unchanged)

On a machine that has never seen this repo: `weaver init clock` + one agent
prompt editing widget.tsx + `weaver dev clock` → ticking translucent clock on
the desktop.

---

# M3 amendment (v0.3)

## `<canvas>` — immediate mode (the ADR 0009 exception)

```tsx
<canvas class="w-[288px] h-[64px]" fps={30} onFrame={(ctx, frame) => { … }} />
```

```ts
interface CanvasFrame { t: number; dt: number }        // seconds
interface CanvasCtx {
  width: number; height: number;                       // logical px
  clear(color?: string): void;                         // default: transparent
  fillRect(x: number, y: number, w: number, h: number, color: string): void;
  fillRoundRect(x: number, y: number, w: number, h: number, r: number, color: string): void;
  fillCircle(cx: number, cy: number, r: number, color: string): void;
  line(x1: number, y1: number, x2: number, y2: number, width: number, color: string): void;
  polyline(points: number[], width: number, color: string): void;  // flat x,y pairs
}
```

- `fps` capped at 60; omitted → draws once per React render. `fps={0}` pauses
  the frame clock entirely (0% cost) while keeping the last frame on screen —
  the intended idle pattern for data-driven canvases: `fps={active ? 30 : 0}`.
- `onFrame` runs on the native frame clock; commands batch into one
  immediate-mode buffer per frame. Colors are `#rgb/#rrggbb/#rrggbbaa`.
- A canvas with `fps > 0` is an *animated* widget and is billed accordingly
  (ADR 0005); everything outside the canvas stays retained/idle-zero.

## Providers: `audio` and `media` (host-fed)

```ts
useProvider("audio")  // { rms: number, bands: number[] }   32 bands 0..1, 30 Hz,
                      // system loopback — silence sends nothing (idle-zero)
useProvider("media")  // { title: string, artist: string, album: string,
                      //   playing: boolean, positionMs: number, durationMs: number }
                      // change-pushed; 1 Hz position while playing
```

If the host cannot access system loopback, `audio` emits no fabricated frames.
Authorization and route availability remain host diagnostics; they do not add
platform-specific values or branches to Widget source.

Media *control* (play/seek) is deliberately not in M3.

---

# M2 amendment (v0.2)

Everything above stands. M2 turns on the following.

## Interactive elements (were "arrives in M2")

```ts
<button onPress={() => …} class="…">{children}</button>   // pressable box
<slider value={n} max={n} onChange={(v: number) => …} />  // horizontal, drag+click
<image src="./assets/foo.png" class="…" />                // LOCAL widget assets only in M2;
                                                          // remote images arrive in M3
```

Handlers run in the widget's JS context; events route through the retained
tree (node id → handler). No hover/focus styling in M2 (arrives with state
variants, unscheduled).

## `weaver.fetch` — the declared-origins network (ADR 0002)

```ts
// Global in widget context (also exported from @weaver/sdk for typing):
function wfetch(url: string, init?: {
  method?: "GET" | "POST";
  headers?: Record<string, string>;
  body?: string;
}): Promise<{ status: number; ok: boolean; text(): Promise<string>; json(): Promise<unknown> }>;
```

- HTTPS only. The URL's host must exactly match an entry in `config.origins`;
  otherwise the promise rejects with
  `OriginNotDeclared: add "api.example.com" to origins in your widget config`.
- `weaver check` statically flags string-literal fetch URLs whose host is not
  declared. Runtime enforcement is authoritative.
- Timeout 15s. No cookies; redirects are returned rather than followed; total
  request and response caps are 5 MB each.

## `useStorage` — scoped persistence (quiet standard surface)

```ts
function useStorage<T>(key: string, initial: T): [T, (next: T | ((prev: T) => T)) => void];
```

JSON-serializable values only; persisted per widget (survives restarts and
`weaver dev` reloads); 64 KB total quota per widget, over-quota writes throw.

## Providers: `cpu` and `memory` (host-fed)

```ts
useProvider("cpu")    // { percent: number, perCore: number[] }      1 Hz
useProvider("memory") // { usedMb: number, totalMb: number, percent: number }  1 Hz
```

Delivered by `weaverd` (the host). `time` remains SDK-local. Subscribing
without the host running is a runtime error that names the fix (`weaver up`);
`weaver dev` auto-starts the host.

`cpu.percent` is whole-machine utilization from 0–100, not the sum of cores;
`perCore` reports the same 0–100 utilization for each logical core. Memory
`usedMb` is physical memory that is not currently free or reclaimable idle
cache, `totalMb` is installed physical memory, and `percent` is their ratio.
These meanings stay platform-neutral even though each host uses its public OS
counters to project them.

## The host and its CLI verbs

```
weaver up | down            start/stop weaverd (singleton, tray-less in M2)
weaver pack <dir>           write portable source to <dir>.weave
weaver install <dir|file.weave> validate, own, build, register, and run source
weaver uninstall <name>     stop + unregister
weaver status               table: name · pid · private-MB · cpu% · uptime (ADR 0005 billing)
```

Portable install amendment: `weaver pack <dir>` writes a deterministic
`.weave` containing source, assets, declared surface, provenance, and lineage.
`weaver install <dir|file.weave>` validates that artifact, builds a
Weaver-owned source copy, and registers the owned path. Only `weaver dev`
registers a developer workspace by reference (ADR 0011).

weaverd supervises widget processes (crash → restart with backoff, 3 strikes
→ stopped + noted in status), fans out providers over local IPC, and samples
per-widget cost. Registrations persist across host restarts.
