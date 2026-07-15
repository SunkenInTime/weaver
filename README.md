# Weaver

**Conjure. Share. Remix.** — desktop widgets built by prompting your agent,
shared as source, remixed by anyone's agent.

Weaver is a cross-platform desktop widget platform (think Rainmeter, rebuilt
for 2026): widgets are single TypeScript components rendered by a native
runtime — no browser, no webview. Each widget is its own crash-isolated
process at **~13 MB of private memory and 0% idle CPU**, drawn with per-pixel
transparency on the desktop layer.

```tsx
import { useProvider, widget } from "@weaver/sdk";

export default widget({
  name: "Clock",
  size: [240, 110],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
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

That file is a complete widget. It is also the *distribution format*: a
shared Weaver widget is always its source — what you read is what runs, and
every install is a potential remix.

## Status: v0 (pre-alpha), Windows + macOS port in progress

The conjure and source-sharing loops work end to end on Windows and macOS:
scaffold → agent edits the TSX → `weaver check` (agent-readable errors) →
`weaver dev` → live widget. The portable `init` / `check` / `bundle` / `pack` /
`inspect` / `install` / `uninstall` / `logs` lifecycle uses the same `.weave`
bytes and install-owned source boundary on both platforms. macOS now has its
native supervisor, acknowledged lifecycle, crash/backoff recovery, process
cost status, and state-preserving dev hot swap from PR 10 of the
[Lane D implementation plan](docs/macos-port-brief.md). See the honest milestone
notes in [`docs/m0-results.md`](docs/m0-results.md) and
[`docs/m1-results.md`](docs/m1-results.md), plus the portable artifact evidence
in [`docs/weave-results.md`](docs/weave-results.md). Expect everything to
change.

Host-owned CPU, memory, and audio providers now run on both platforms and stay
off with no subscriber. macOS audio uses one public Core Audio process tap and
one shared analysis/fan-out pipeline; unavailable permission or hardware is
reported explicitly and never replaced with fake frames. Media remains
explicit port work, not a stubbed capability.

## Quickstart

Prerequisites: Windows 11 or macOS 14.2+, [Node 22+](https://nodejs.org), and
[Zig 0.16.0](https://ziglang.org/download/) on PATH.

```powershell
git clone --recurse-submodules https://github.com/SunkenInTime/weaver
cd weaver
npm install
cd runtime; zig build -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off; cd ..

node cli\bin\weaver.js init myclock
node cli\bin\weaver.js dev myclock

node cli\bin\weaver.js pack myclock
node cli\bin\weaver.js install myclock.weave
```

On macOS, build the runtime with `cd runtime && zig build
-Doptimize=ReleaseFast`, build the host with `cd host && zig build
-Doptimize=ReleaseFast`, and use `node cli/bin/weaver.js`. `up`, `down`,
`status`, `dev`, and all artifact commands above are available. Before running
an audio-reactive Widget, authorize the signed host identity in the foreground:

```sh
node cli/bin/weaver.js audio authorize
```

Or do it the intended way: point your coding agent at
[`skills/conjure-widget/SKILL.md`](skills/conjure-widget/SKILL.md) and ask it
for the widget you actually want.

## How it's put together

| Path | What |
|---|---|
| `runtime/` | `weaver-widget[.exe]` — Zig, embeds QuickJS-NG, renders via the Native SDK fork (submodule `runtime/native-sdk`) |
| `sdk/` | `@weaver/sdk` — the authoring API: reconciler, hooks, class compiler. Contract frozen in [`sdk/CONTRACT.md`](sdk/CONTRACT.md) |
| `cli/` | `weaver` — init / check / bundle / dev / pack / inspect / install / uninstall / logs |
| `skills/` | agent skills (conjuring is the primary authoring path) |
| `docs/adr/` | why things are the way they are — start here to understand the project |
| `CONTEXT.md` | the domain glossary |

The substrate is a fork of
[vercel-labs/native](https://github.com/vercel-labs/native)
([our fork](https://github.com/SunkenInTime/native), branch `weaver-main`)
adding Weaver-owned desktop-widget windowing, capacity, and presentation
semantics. The general static-TLS problem discovered while profiling the fork
was reported as [vercel-labs/native#114](https://github.com/vercel-labs/native/issues/114)
and fixed upstream separately; the Weaver product surface remains in the fork.
