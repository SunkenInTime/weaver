# Media PR 05 attended-Mac verification

Date: 2026-07-26

Branch: `media/05-mac-verify`

Stack head verified: `0d3f16311f728c969ea87a91e256e0de42cd7c3a`

Machine:

- M2 Mac (`arm64`)
- macOS 26.5.1 (25F80)
- Zig 0.16.0
- Node.js 23.11.0
- npm 11.3.0

Decision: **FAIL — stopped at the handoff's required local-build gate.**

No attended product or visual claim is made by this report. The runtime
ReleaseFast build passed, but the host ReleaseFast build could not start the
vendored MediaRemote adapter build because `cmake` is absent from this Mac.
The handoff explicitly says to stop and report when a local build fails, so
the daemon, live media, transport, lifecycle, idle-zero, Noro, channel
recovery, and secondary drag checks were not run.

## Preflight

`git pull --ff-only` fast-forwarded local `master` from `c579c03` to
`b1199b5`. No commit was made on `master`.

PR #35 was still pinned at the handoff head `0d3f163`. PR #36 was at
`d92365c`. Their current Actions runs (`30221054684` and `30221050486`) were
not test failures: all jobs were cancelled during `actions/checkout@v4`, and
all build/test steps were skipped. This report therefore proceeded to the
required local build gate.

Root install:

```text
$ npm ci
> weaver-monorepo@0.1.0 postinstall
> npm run build
...
added 34 packages, and audited 37 packages in 2s
found 0 vulnerabilities
```

Result: **PASS**

Runtime:

```text
$ cd runtime
$ zig build -Doptimize=ReleaseFast
```

Result: **PASS**

Host:

```text
$ cd host
$ zig build -Doptimize=ReleaseFast
install
+- run /usr/bin/ditto
   +- run cmake
      +- run cmake failure
error: failed to spawn and capture stdio from cmake: FileNotFound
failed command: cmake -S /Users/dara/Dev/Projects/weaver/host/assets/mediaremote-adapter -B /Users/dara/Dev/Projects/weaver/host/.zig-cache/mediaremote-adapter -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2
```

Result: **FAIL**

`command -v cmake`, `/opt/homebrew/bin/cmake`,
`/usr/local/bin/cmake`, and `brew list --versions cmake` all found no CMake
installation. `host/build.zig` invokes `cmake` directly for macOS, while the
root README and handoff only name Zig 0.16.0 and `npm ci` as prerequisites.
No system-level package was installed during this run.

## Acceptance results

| Item | Result | Evidence |
|---|---|---|
| 1. Build + daemon, metadata, art cache/prune | **FAIL** | Runtime build passed; host build stopped before compilation because `cmake` was not found. Daemon and live checks not run. |
| 2. Transport and no-session seek honesty | **NOT RUN** | Blocked by item 1's required build gate. |
| 3. Adapter/player lifecycle and non-1x playback rate | **NOT RUN** | Blocked by item 1's required build gate. |
| 4. Paused/silent idle-zero measurement over at least 60 s | **NOT RUN** | Blocked by item 1's required build gate. |
| 5. Noro macOS visual/interaction gate | **NOT RUN** | Blocked by item 1's required build gate. No captures were produced, so no visual claim is made. |
| 6. Runtime channel-failure recovery | **NOT RUN** | Blocked by item 1's required build gate. |
| Secondary: drag and position persistence | **NOT RUN** | Blocked by item 1's required build gate. |

## Next executable task

Make CMake an explicit macOS build prerequisite (or provide a repository-
scoped hermetic CMake path), then repeat this handoff from item 1 on the same
stack head or its reviewed successor. Do not treat installing CMake alone as
closing any attended acceptance item.
