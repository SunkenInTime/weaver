# weaverd

`weaverd.exe` is intentionally a standalone Zig Win32 process, not a Native
SDK application. M2 has no host UI, so constructing the Native renderer and
QuickJS in the one always-running process would spend memory without buying a
capability. A later settings window can be a separate Native client or justify
changing that boundary explicitly.

Build with the repository's pinned Zig toolchain and an installed Windows 10
SDK. The build discovers the SDK through the same registry metadata as Zig and
uses its C++/WinRT projection plus `windowsapp.lib`; no package-manager C++
dependency is required.

```powershell
$env:PATH = 'E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0;' + $env:PATH
zig build -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseFast
```

The TypeScript CLI remains the sole widget checker/bundler. The host invokes
that CLI only when `widget.tsx` is newer than `dist/bundle.js` or the dist
manifest is missing; it never grows a second TSX pipeline.

Operational state lives under `%LOCALAPPDATA%\weaver`: `registry.json` is the
persistent registration index, `widgets/` contains validated install-owned
source copies, and `status.json` is the atomically replaced two-second cost
snapshot consumed by `weaver status`. The supervisor uses a
named mutex for singleton ownership and named events for reload/shutdown.
Provider data has a separate outbound named pipe per subscribed widget.

M3 keeps the provider ownership obvious:

- WASAPI loopback and SMTC ABI work live in one C++ file. The audio boundary
  returns normalized mono samples; the 2048-point FFT, 32 logarithmic bands,
  AGC, silence state, JSON formatting, and fan-out are Zig.
- Audio capture exists only while at least one running widget subscribes. It
  emits one JSON line at 30 Hz while audible, emits zeros during the two-second
  decay hold, sends one final zero, then stops pipe traffic until sound resumes.
- SMTC is polled once per second only while subscribed. Serialized equality
  makes metadata change-pushed and naturally retains the required 1 Hz playing
  position update.
