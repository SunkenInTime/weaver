---
name: conjure-widget
description: Create or remix a Weaver desktop widget from a natural-language request and take it through scaffold, TSX editing, static checking, and live desktop preview. Use for "make me a widget", "build a desktop widget", "conjure a clock/status surface", or requests to change an existing Weaver widget.
---

# Conjure a Weaver widget

Turn the request into one checked `widget.tsx`, then launch the real desktop
surface. Preserve the user's visual intent; ask only when a missing choice would
materially change the widget.

## Workflow

1. From the Weaver repository root, scaffold with
   `npx --no-install weaver init <name>` unless the widget directory exists.
2. Edit `<name>/widget.tsx`. Keep one default export in the literal form
   `export default widget({ ... }, () => <... />);`. Do not compute config.
3. Run `npx --no-install weaver check <name>` and fix every error. Treat its
   messages as the contract; never bypass a dated M2/M3 refusal.
4. Run `npx --no-install weaver dev <name>`. Leave it running so the user can
   inspect the widget. Saving `widget.tsx` checks, bundles, and restarts it.
5. Report what appeared and any M1 boundary that constrained the request.

## Authoring contract

Import from `@weaver/sdk`. Available hooks are `useState`, `useRef`,
`useEffect`, `useInterval`, and `useProvider("time")`. Calling
`useProvider("time")` requires `subscribe: ["time"]` in the literal config.

Config fields:

```ts
{
  name: string,
  size: [number, number],
  anchor?: {
    monitor?: "primary",
    corner: "top-left" | "top-right" | "bottom-left" | "bottom-right",
    offset?: [number, number]
  },
  layer?: "desktop" | "normal" | "topmost",
  clickThrough?: boolean,
  subscribe?: ["time"],
  origins?: string[],
  capabilities?: []
}
```

Render with `<column>`, `<row>`, `<panel>`, `<text>`, and path-backed
`<icon>`. Text children must be strings or numbers. Icons take no children.
Use a literal full-catalog Lucide name (`<icon name="play" />`) or literal
custom SVG path data (`<icon d="M 9 5 L 21 12 L 9 19 Z" />`); custom paths
may add `viewBox` and positive numeric `stroke`. Size icons geometrically with
`w-*`/`h-*` and color them with `text-*`. Types declare `<image>`, `<button>`,
and `<slider>`, but they arrive in M2; `<canvas>` arrives in M3.

## Class utilities

One scale unit is 4 px. Use only:

| Utility | Meaning |
|---|---|
| `p-N`, `p-[Npx]` | Uniform padding |
| `gap-N`, `gap-[Npx]` | Flex gap |
| `rounded`, `rounded-{md,lg,xl,2xl,3xl,full}`, `rounded-[Npx]` | Radius |
| `bg-[#rgb]`, `bg-[#rrggbb]`, `bg-[#rrggbbaa]`, optional `/NN` | Background and alpha |
| `text-[#rgb/#rrggbb/#rrggbbaa]` | Text color |
| `text-{xs,sm,base,lg,xl,2xl,3xl,4xl}` | Text size |
| `font-{light,normal,medium,semibold,bold}` | Text weight |
| `opacity-NN` | Node opacity percent |
| `items-{start,center,end,baseline}` | Cross-axis alignment |
| `justify-{start,center,end,between}` | Main-axis alignment |
| `grow` | Flex grow 1 |
| `w-N`, `w-[Npx]`, `h-N`, `h-[Npx]` | Fixed size |
| `truncate` | Single-line ellipsis on text |

Unknown utilities are errors. Split padding (`px-`/`py-`), borders, shadows,
gradients, hover/state variants, transitions, and animations arrive in M2+.

## M1 boundaries

- Use only the `time` provider. It supplies `hh`, `mm`, `ss`, `weekday`,
  `month`, `day`, `year`, and `epochMs` once per second while subscribed.
- Do not create input elements or fake them with inert panels; interactions
  arrive in M2.
- Do not fetch. `origins` is validated now, but network access arrives in M2.
- Keep `capabilities` empty. The capability ladder arrives in M2.
- Plain TSX is bundled automatically; do not add dependencies or external
  imports beyond `@weaver/sdk`.
