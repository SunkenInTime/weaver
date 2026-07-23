# Weaver

**Conjure. Share. Remix.** — desktop widgets built by prompting your agent,
shared as source, remixed by anyone's agent.

Weaver is a cross-platform desktop widget platform (think Rainmeter, rebuilt
for 2026): widgets are single TypeScript components rendered by a native
runtime — no browser, no webview. Each widget is its own crash-isolated
process, drawn with per-pixel transparency on the desktop layer. Current
platform-specific cost measurements are published with the milestone results;
the corrected macOS retained renderer is roughly 28.5 MB for the measured quiet
Clock Widget and is not represented by the older Windows memory number.

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

## Status: v0 (pre-alpha), Windows + macOS developer builds

The conjure and source-sharing loops work end to end on Windows and macOS:
scaffold → agent edits the TSX → `weaver check` (agent-readable errors) →
`weaver dev` → live widget. The portable `init` / `check` / `bundle` / `pack` /
`inspect` / `install` / `uninstall` / `logs` lifecycle uses the same `.weave`
bytes and install-owned source boundary on both platforms. macOS now has its
native supervisor, acknowledged lifecycle, crash/backoff recovery, process
cost status, state-preserving dev hot swap, retained Metal renderer, and
host-owned providers from the stacked
[Lane D implementation plan](docs/macos-port-brief.md). See the honest milestone
notes in [`docs/m0-results.md`](docs/m0-results.md) and
[`docs/m1-results.md`](docs/m1-results.md), plus the portable artifact evidence
in [`docs/weave-results.md`](docs/weave-results.md). Expect everything to
change.

Host-owned CPU, memory, and audio providers now run on both platforms and stay
off with no subscriber. macOS audio uses one public Core Audio process tap and
one shared analysis/fan-out pipeline; unavailable permission or hardware is
reported explicitly and never replaced with fake frames. macOS media is
explicitly unavailable in v0: public APIs at the 14.2 floor do not observe
other applications' Now Playing sessions, so Weaver sends no fake media frame
and does not depend on private MediaRemote APIs. See
[`ADR 0015`](docs/adr/0015-macos-media-provider-unavailable.md).

## Quickstart

Prerequisites: Windows 11 or macOS 14.2+, [Node 22+](https://nodejs.org), and
[Zig 0.16.0](https://ziglang.org/download/) on PATH. Clone the reviewed Native
SDK fork commit with the repository:

```sh
git clone --recurse-submodules https://github.com/SunkenInTime/weaver
cd weaver
npm ci
```

On macOS:

```sh
(cd runtime && zig build -Doptimize=ReleaseFast)
(cd host && zig build -Doptimize=ReleaseFast)

node cli/bin/weaver.js init myclock
node cli/bin/weaver.js check myclock
node cli/bin/weaver.js dev myclock
```

On Windows PowerShell:

```powershell
Push-Location runtime
zig build -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off
Pop-Location
Push-Location host
zig build -Doptimize=ReleaseFast
Pop-Location

node cli\bin\weaver.js init myclock
node cli\bin\weaver.js check myclock
node cli\bin\weaver.js dev myclock
```

Stop `dev` with Ctrl-C. The portable artifact loop is the same on both systems:

```sh
node cli/bin/weaver.js pack myclock
node cli/bin/weaver.js inspect myclock.weave
node cli/bin/weaver.js install myclock.weave
node cli/bin/weaver.js uninstall Myclock
```

On Windows, use backslashes in the CLI path. Before running an audio-reactive
Widget on macOS, authorize the signed host identity in the foreground:

```sh
node cli/bin/weaver.js audio authorize
```

### macOS diagnostics and permission reset

```sh
node cli/bin/weaver.js status --json
node cli/bin/weaver.js logs "Clock"
node cli/bin/weaver.js logs "Clock" --follow
codesign --verify --deep --strict host/zig-out/Weaverd.app
plutil -p host/zig-out/Weaverd.app/Contents/Info.plist
```

To discard every privacy decision associated with the development host bundle,
stop it, reset that one bundle identity, rebuild, and authorize again:

```sh
node cli/bin/weaver.js down
tccutil reset All com.sunkenintime.weaver.host
(cd host && zig build -Doptimize=ReleaseFast)
node cli/bin/weaver.js audio authorize
```

`tccutil reset All` is intentionally bundle-scoped but broader than audio: it
removes every saved privacy choice for that host ID. Diagnostics never require
disabling SIP, Gatekeeper, the firewall, or any global security control.

### Development support matrix

| Target | Automated gate | Physical status |
|---|---|---|
| Windows 11 x64 | Build, runtime/host/unit, portable artifact and example surfaces | Existing production/reference platform |
| macOS 14.2+ Apple silicon | Clean build, headless suites, real AppKit Widget/session/provider/crash/teardown gate | M2 MacBook Air measured and visually exercised |
| macOS 14.2+ Intel | Build, runtime/host/unit, portable artifact and nonvisual daemon lifecycle | Physical Intel hardware unverified |
| Linux | None | Unsupported |

The initial distribution is a source checkout and ad-hoc-signed developer host,
not a notarized installer, login item, App Store product, or universal package.
The remaining physical limits are explicit: external-display arrangements,
Stage Manager/Space/fullscreen/lock and sleep/wake coverage, post-grant System
Audio revocation and physical route recovery, Bluetooth/AirPlay, and Developer
ID notarization are not inferred from automation. OS screen capture, Show
Desktop, and integrated-output System Audio capture now have physical evidence.
macOS media is unavailable by ADR 0015.
See [`macos-m12-results.md`](docs/macos-m12-results.md) and the live
[`macos-run-status.md`](docs/macos-run-status.md) for the exact gates and
blockers.

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

## License

Weaver is licensed under the [Apache License 2.0](LICENSE).
Third-party and vendored components remain subject to their respective licenses.
