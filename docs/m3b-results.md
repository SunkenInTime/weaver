# M3b results: audio and media providers

M3b completes the provider half of CONTRACT.md v0.3. `weaverd` now owns one
shared WASAPI loopback/FFT pipeline and one shared Windows SMTC session view,
then fans their contract-shaped JSON lines through the existing per-widget
named pipes. The Native SDK fork remains unchanged at `9611804b`.

The live proofs are [the audio visualizer](../examples/visualizer/widget.tsx)
and [Now Playing](../examples/now-playing/widget.tsx). The best live spectrum
capture is [m3b-visualizer-live.png](m3b-visualizer-live.png); two adjacent
captures, [live-1](m3b-visualizer-live-1.png) and
[live-2](m3b-visualizer-live-2.png), show different real loopback frames.
[m3b-now-playing.png](m3b-now-playing.png) shows metadata read from Windows'
actual SMTC session.

## Provider design

### Audio

The Windows boundary in `host/src/windows_providers.cpp` opens the default
`eRender/eConsole` endpoint in shared `AUDCLNT_STREAMFLAGS_LOOPBACK` mode,
normalizes the endpoint's float/PCM mix format, and mixes its channels to
mono. The dependency-free Zig analyzer then owns:

1. a rolling 2,048-sample Hann window;
2. an iterative radix-2 FFT;
3. 32 logarithmic energy bands from 20 Hz through 16 kHz;
4. a slowly decaying per-band peak AGC and 36 dB display range; and
5. JSON rounding/serialization into one `rms + bands[32]` line.

Capture, FFT, and serialization are never instantiated when no running widget
subscribes to `audio`. With a subscriber, a deadline accumulator preserves a
30 Hz long-run rate despite Windows timer quantization. A live ten-second
counter window delivered **30.29 lines/s**.

Below the 0.0005 RMS silence floor, the provider sends zero bands during a
two-second decay hold. It then sends one final zero and stops all pipe writes.
In the live test the status counter reached 1,930, remained exactly 1,930 for
the following 15 seconds, and resumed when sound returned. The endpoint id is
checked once per second; default-device changes or capture invalidation tear
down the client and reopen the new default endpoint without restarting the
host.

The runtime drains high-rate provider data on an existing fast canvas/timer
turn where possible. A non-canvas audio consumer gets a dedicated 33 ms Native
effect timer. CPU/memory/media-only widgets retain the old 1 Hz drain and do
not acquire a high-rate wakeup.

### Media

The same C++ file uses the Windows SDK's C++/WinRT projection for
`GlobalSystemMediaTransportControlsSessionManager`. Once per second while a
widget subscribes it reads the current session's media properties, playback
status, and timeline. Serialized equality suppresses unchanged paused/no-
session frames; a playing position naturally changes once per second.

The live source was Windows Media Player
`Microsoft.ZuneMusic_11.2605.14.0`, opened with
`C:\Windows\Media\Ring05.wav`. SMTC reported the actual title `Ring05`,
playing/paused state, position, and duration. The WAV has no artist/album tags,
so the widget honestly renders `Unknown artist`; those fields remain wired and
typed for tagged media. The proof used the desktop screenshot after playback
completed, which is why it shows `PAUSED` and a full position bar.

The position bar is 24 retained four-pixel segments. Weaver's frozen class
contract requires every class string to be statically checkable, so the M3
widget selects between literal filled/unfilled segment nodes instead of adding
an undeclared dynamic-width/style escape hatch.

## Measurements

Windows 11, ReleaseFast, `-Dweb-layer=exclude -Dtrace=off` for the widget
runtime. CPU is `TotalProcessorTime` over 15 seconds expressed as percent of
one logical core. Private WS is
`Win32_PerfFormattedData_PerfProc_Process.WorkingSetPrivate`.

| State | weaverd CPU | weaverd private WS | Visualizer CPU | Visualizer private WS |
|---|---:|---:|---:|---:|
| Loopback playing, 30.29 provider frames/s | **0.73%** | **2.75 MiB** | **4.37%** | 15.03 MiB |
| Silent after final zero; pipe counter stopped | **0.31%** | **2.75 MiB** | **2.39%** | 12.85 MiB |
| No audio subscriber (media subscriber retained) | **0.00%** | 2.80 MiB | — | — |

The active host is well below the 3% target. Its seven-to-eight threads include
COM/WinRT infrastructure when SMTC is active; with no audio subscription the
capture object is absent and the host returns to an effectively zero CPU wait.
The final `weaverd.exe` is 1,439,232 bytes (1.37 MiB).

The visualizer's silent CPU does not reach zero because `<canvas fps={30}>`
still owns the M3a frame clock. Once all levels reach zero, identical command
batches avoid dirty raster work, but the Native SDK's known timer scheduling
pass remains. Pipe traffic and host FFT work are genuinely zero. Removing the
remaining 2.39% requires an SDK-level demand-driven canvas clock or an explicit
provider active/silent signal, neither of which is in the frozen M3 contract.

## Live verification

- `System.Media.SoundPlayer` looped `C:\Windows\Media\Ring05.wav` for the
  WASAPI screenshots and active measurements. All 28 bars visibly changed
  across the three captures.
- Stopping the player made the bars decay to an empty card within the two-
  second hold; after four seconds `audioSilent` was true, and the status
  `audioPipeFrames` counter did not move during the next 15 seconds.
- Modern Windows Media Player produced the SMTC title/state/timeline proof.
- The M2b CPU/memory provider still rendered changing real system values;
  see [m3b-system-regression.png](m3b-system-regression.png).
- `weaver down` cleanly stopped the host and all widgets. SoundPlayer and
  Windows Media Player were also terminated. The pre-test user registry was
  restored afterward.

## Automated verification

- `npm run typecheck`: pass.
- `npm test`: pass, 7/7. The reconciler test now dispatches and renders both
  audio and media provider frames.
- `host: zig build test -Doptimize=ReleaseFast`: pass. Tests include a
  deterministic 1 kHz FFT placement, the 32-band wire shape, scheduler
  deadline behavior, media JSON escaping, registry, status, and backoff.
- `host: zig build -Doptimize=ReleaseFast`: pass.
- `runtime: zig build test`: pass.
- `runtime: zig build -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off`:
  pass.
- `weaver check` and `weaver bundle`: pass for visualizer, Now Playing, and
  the unchanged system monitor.

## Build

Zig 0.16.0, Node.js 20.11+, and an installed Windows 10 SDK are required. The
host build discovers the SDK installation/version from the Windows registry
and links its C++/WinRT projection; there is no vendored DSP or WinRT package.

```powershell
git submodule update --init --recursive
$env:PATH = 'E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0;' + $env:PATH
npm install
npm run typecheck
npm test

Push-Location host
zig build test -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast
Pop-Location

Push-Location runtime
zig build test
zig build -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off
Pop-Location

node cli\dist\index.js install examples\visualizer
node cli\dist\index.js install examples\now-playing
```

## Limitations

- Default endpoint recovery is implemented through a one-second endpoint-id
  check plus reopen-on-capture-failure. A live hardware default-device switch
  was not performed because it would modify the user's system audio routing.
- SMTC chooses Windows' current session. M3 deliberately has no source picker,
  album art, transport controls, or media control API.
- WASAPI is Windows-only in M3b. The provider surface is cross-platform, but
  macOS/Linux capture implementations remain future platform work.
