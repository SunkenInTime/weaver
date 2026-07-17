# macOS Core Audio tap feasibility spike

This is a disposable PR 12 measurement harness, not production provider code.
It creates one private, unmuted, global mono Core Audio process tap, attaches it
to a private aggregate device, starts one IO proc, and records the callback,
signal, format, and in-memory fan-out metrics as JSON.

Build the unsigned application bundle:

```sh
spikes/macos-audio-tap/build.sh
```

Then launch it as an application so macOS can associate the
`NSAudioCaptureUsageDescription` string and TCC decision with its bundle ID:

```sh
open -W "spikes/macos-audio-tap/build/Weaver Audio Tap Spike.app" --args \
  --duration 5 --fanout 3 --play-sound /System/Library/Sounds/Glass.aiff \
  --output /tmp/weaver-audio-tap-result.json
```

`--setup-only` stops before the permission-gated IO proc registration. It is
useful for verifying public tap/format/private-aggregate setup independently
from an unattended permission prompt; it does not claim that capture worked.

Use `codesign --force --sign -` on the bundle for the ad-hoc-signed developer
case. The result file intentionally retains every Core Audio `OSStatus` so a
permission denial or device failure cannot look like silence.
