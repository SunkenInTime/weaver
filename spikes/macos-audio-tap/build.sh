#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_root=${1:-"$root/build"}
app="$build_root/Weaver Audio Tap Spike.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$root/Info.plist" "$app/Contents/Info.plist"
xcrun clang -fobjc-arc -fblocks -O2 -mmacosx-version-min=14.2 \
  -framework CoreAudio -framework Foundation \
  "$root/main.m" -o "$app/Contents/MacOS/WeaverAudioTapSpike"

printf '%s\n' "$app"
