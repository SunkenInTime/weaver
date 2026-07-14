# weaverd

`weaverd.exe` is intentionally a standalone Zig Win32 process, not a Native
SDK application. M2 has no host UI, so constructing the Native renderer and
QuickJS in the one always-running process would spend memory without buying a
capability. A later settings window can be a separate Native client or justify
changing that boundary explicitly.

Build with the repository's pinned Zig toolchain:

```powershell
$env:PATH = 'E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0;' + $env:PATH
zig build -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseFast
```

The TypeScript CLI remains the sole widget checker/bundler. The host invokes
that CLI only when `widget.tsx` is newer than `dist/bundle.js` or the dist
manifest is missing; it never grows a second TSX pipeline.

Operational state lives under `%LOCALAPPDATA%\weaver`: `registry.json` is the
persistent source-path registry and `status.json` is the atomically replaced
two-second cost snapshot consumed by `weaver status`. The supervisor uses a
named mutex for singleton ownership and named events for reload/shutdown.
Provider data has a separate outbound named pipe per subscribed widget.
