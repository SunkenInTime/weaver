#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
sdk=$(xcrun --sdk macosx --show-sdk-path)
audit_root=$(mktemp -d "${TMPDIR:-/tmp}/weaver-mediaremote-audit.XXXXXX")
trap 'rm -rf "$audit_root"' EXIT INT TERM

public_hits="$audit_root/public-sdk.txt"
private_candidates="$audit_root/private-candidates.txt"
signatures="$audit_root/signatures.txt"
linked="$audit_root/linked.txt"
symbols="$audit_root/symbols.txt"

find "$sdk/System/Library/Frameworks" "$sdk/usr/include" \
  -iname '*MediaRemote*' -print >"$public_hits" 2>/dev/null || true

private_framework=/System/Library/PrivateFrameworks/MediaRemote.framework
if [ -d "$private_framework" ]; then
  find "$private_framework" -maxdepth 5 -type f -perm -111 -print \
    >"$private_candidates" 2>/dev/null || true
else
  : >"$private_candidates"
fi

: >"$signatures"
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  {
    printf '%s\n' "FILE=$candidate"
    codesign -dvv "$candidate" 2>&1 || true
  } >>"$signatures"
done <"$private_candidates"

host_binary="$root/host/zig-out/Weaverd.app/Contents/MacOS/weaverd"
test -x "$host_binary"
otool -L "$host_binary" | grep -i MediaRemote >"$linked" || true
nm -u "$host_binary" 2>/dev/null | grep -i MediaRemote >"$symbols" || true

python3 - "$sdk" "$public_hits" "$private_candidates" "$signatures" "$linked" "$symbols" <<'PY'
import json
import pathlib
import sys

sdk, public_path, candidate_path, signature_path, linked_path, symbol_path = sys.argv[1:]

def lines(path):
    return [line for line in pathlib.Path(path).read_text().splitlines() if line]

public = lines(public_path)
linked = lines(linked_path)
symbols = lines(symbol_path)
result = {
    "sdkRoot": sdk,
    "publicSdkMediaRemotePaths": public,
    "privateFrameworkExecutableCandidates": lines(candidate_path),
    "privateCandidateCodeSignOutput": lines(signature_path),
    "weaverMediaRemoteDependencies": linked,
    "weaverMediaRemoteUndefinedSymbols": symbols,
    "executionGate": {
        "realMetadataFrame": False,
        "deliveredCommand": False,
        "status": "BLOCKED",
        "reason": "static inventory cannot prove a real system-player frame or delivered command",
    },
}
print(json.dumps(result, indent=2, sort_keys=True))
assert not public, "MediaRemote unexpectedly appeared in the public SDK surface"
assert not linked, "Weaver host unexpectedly links MediaRemote"
assert not symbols, "Weaver host unexpectedly imports a MediaRemote symbol"
PY
