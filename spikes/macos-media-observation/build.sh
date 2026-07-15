#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_root=${1:-"$root/build"}
probe="$build_root/macos-media-observation"
publisher="$build_root/publisher.json"
observer="$build_root/observer.json"
negative_log="$build_root/music-player-unavailable.log"

rm -rf "$build_root"
mkdir -p "$build_root"

xcrun clang -fobjc-arc -O2 -mmacosx-version-min=14.2 \
  -framework Foundation -framework MediaPlayer \
  "$root/main.m" -o "$probe"

"$probe" publish >"$publisher" &
publisher_pid=$!
trap 'kill "$publisher_pid" 2>/dev/null || true' EXIT INT TERM
sleep 0.25
"$probe" observe >"$observer"
wait "$publisher_pid"
trap - EXIT INT TERM

if xcrun clang -fobjc-arc -Werror -mmacosx-version-min=14.2 \
  -framework Foundation -framework MediaPlayer \
  "$root/music_player_unavailable.m" -o "$build_root/music-player-unavailable" \
  >"$negative_log" 2>&1; then
    echo "expected MPMusicPlayerController to be unavailable on macOS" >&2
    exit 1
fi

python3 - "$publisher" "$observer" "$negative_log" <<'PY'
import json
import pathlib
import sys

publisher = json.loads(pathlib.Path(sys.argv[1]).read_text())
observer = json.loads(pathlib.Path(sys.argv[2]).read_text())
negative_log = pathlib.Path(sys.argv[3]).read_text()

assert publisher["hasNowPlayingInfo"] is True, publisher
assert publisher["title"] == "Weaver Public API Probe", publisher
assert observer["hasNowPlayingInfo"] is False, observer
assert observer["title"] is None, observer
assert "unavailable" in negative_log and "macOS" in negative_log, negative_log

print(json.dumps({
    "publisher": publisher,
    "concurrentObserver": observer,
    "musicPlayerControllerCompile": {
        "succeeded": False,
        "expected": "unavailable on macOS",
        "diagnostic": next(
            line.strip() for line in negative_log.splitlines()
            if "unavailable" in line and "macOS" in line
        ),
    },
}, indent=2, sort_keys=True))
PY

