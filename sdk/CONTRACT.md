# @weaver/sdk — public API contract (v0, frozen for M1)

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
weaver bundle <dir>      esbuild → dist/bundle.js (what `install` will use later)
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
