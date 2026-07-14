# M2b results: host, providers, supervision, and cost accounting

M2b adds the windowless `weaverd.exe` host without moving widget ownership
out of source directories. The live provider proof is
[`../examples/system/widget.tsx`](../examples/system/widget.tsx), and the
desktop capture is [`m2b-system.png`](m2b-system.png).

## Build from a clean checkout

Requirements are Node.js 20.11+, npm, and Zig 0.16.0 at the path below. The
Native fork remains the pinned `runtime/native-sdk` submodule and was not
modified.

```powershell
git submodule update --init --recursive
$env:PATH = 'E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0;' + $env:PATH
npm install
npm test
npm run typecheck

Push-Location runtime
zig build test -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off
zig build -Doptimize=ReleaseFast -Dweb-layer=exclude -Dtrace=off
Pop-Location

Push-Location host
zig build test -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast
Pop-Location
```

The host is deliberately plain Zig/Win32 rather than a headless Native SDK
app. It has no M2 UI, so loading the renderer and QuickJS into the one process
that is always running would spend memory without providing a capability.

## Operator surface

```powershell
node cli\dist\index.js up
node cli\dist\index.js install examples\clock
node cli\dist\index.js install examples\pomodoro
node cli\dist\index.js status
node cli\dist\index.js status --json
node cli\dist\index.js uninstall Clock
node cli\dist\index.js down
```

- A named mutex makes the host a singleton. Named events implement reload and
  shutdown without adding a permanent control server.
- `%LOCALAPPDATA%\weaver\registry.json` is atomically written and contains
  only `{name, sourcePath, enabled}` registrations. The source path is the
  artifact identity; install never copies it.
- The CLI remains the only checker/bundler. Before launch, the host invokes
  that CLI only when `widget.tsx` is newer than `dist/bundle.js` or either dist
  artifact is absent.
- `weaver dev` starts the host when necessary, creates a host-managed
  registration for an otherwise uninstalled widget, and signals a restart
  after each successful rebuild. Ctrl+C removes that temporary registration.
- `weaver down`, uninstall, and watched restarts post `WM_CLOSE`, wait up to
  1.5 seconds for QuickJS's final storage flush, then retain termination only
  as a bounded fallback.

## Providers and idle discipline

For a widget declaring `cpu` or `memory`, the host creates one outbound named
pipe and passes its name in `WEAVER_HOST_PIPE`. JSON-lines are pushed host to
widget; QuickJS is never entered from the reader thread. The runtime drains
frames on its Native loop and the SDK fans them to subscribed hooks.

- CPU uses one `NtQuerySystemInformation(SystemProcessorPerformanceInformation)`
  sample for aggregate and per-core values.
- Memory uses one `GlobalMemoryStatusEx` sample.
- Sampling is 1 Hz and is skipped entirely when no running widget requests a
  host provider. Rounded CPU frames (0.1 point) and memory frames (1 MiB) are
  sent only after a value changes; one sample is fanned to every subscriber.
- A widget without host-fed subscriptions gets no pipe, no reader thread, and
  no provider polling timer.
- Without a pipe, `useProvider("cpu")` and `useProvider("memory")` fail with
  `Provider "cpu" requires weaverd; run "weaver up"` (provider name varies).

The first live build exposed Zig's 16 MiB default thread-stack reservation in
provider widgets. The fixed-buffer pipe reader now reserves 256 KiB. In the
same System Monitor workload, process private usage fell from 39.1 MiB to
23.3 MiB; final private working set was 14.85 MiB.

## Supervision and billing proof

The host checks process handles without polling child stdout. Failures receive
three restart attempts at 1 second, 5 seconds, and 30 seconds. A fourth failed
launch inside five minutes exhausts those three strikes and records a stopped
reason. A five-minute healthy gap resets the crash window.

Mechanical observations:

- Killing Clock PID `55132` produced PID `26376`; status returned to `running`
  with uptime reset to one second.
- The startup-throw proof exhausted all three retries and reported
  `stopped: crashed after 3 restart attempts within 5 minutes: exit code 1`.
- The checked-in Clock and Pomodoro ran concurrently from their registered
  source paths. A representative rolling sample reported 21.7 MiB / 0.5% for
  Clock and 22.3 MiB / 1.3% for Pomodoro.
- `examples/system` rendered changing CPU and memory values from JavaScript.
  Its final status sample was 23.3 MiB private usage and 1.0% of one core;
  private working set was 14.85 MiB.
- `weaver dev examples/system` started a stopped host automatically and
  launched the provider-backed widget.
- `weaver down` left zero `weaverd.exe` and zero `weaver-widget.exe`
  processes. Clock and Pomodoro registrations remained for the next `up`.

Cost accounting samples each widget every two seconds with
`GetProcessMemoryInfo(...).PrivateUsage` plus process-time deltas. The table
and `--json` expose rolling 30-second averages; CPU is percent of one core and
can exceed 100 for multi-threaded work.

## Host footprint

Windows 11, ReleaseFast, supervising Clock and Pomodoro with no host-provider
subscribers. CPU is `TotalProcessorTime` delta over 15 seconds.

| Private WS | Total WS | Private bytes | Threads | CPU / one core | Binary |
|---:|---:|---:|---:|---:|---:|
| 1.41 MiB | 6.68 MiB | 1.77 MiB | 2 | 0.00% | 1,053,696 bytes (1.00 MiB) |

The earlier provider-active sample was still effectively idle: 0.21% of one
core over 15 seconds, dominated by Windows timer/accounting granularity.

## Honest caveats

- The Native fork has no app-owned cross-thread wake/completion hook. A
  provider-backed runtime therefore uses one 1 Hz Native effect timer to drain
  its pipe. The host sends only changed frames, but an unchanged subscribed
  widget can still incur the fork's known no-op timer rebuild once per second.
- Crash-stopped state and its reason live in the running supervisor/status
  document. Registrations persist, but restarting weaverd grants a stopped
  widget a fresh three-retry budget.
- A force-killed `weaver dev` CLI cannot run its Ctrl+C cleanup and may leave
  an otherwise temporary registration. The next `uninstall <name>` is the
  explicit recovery; the widget process itself still remains supervised.
- Status is published atomically every two seconds, so an immediate read can
  show the previous PID for up to one accounting interval.
