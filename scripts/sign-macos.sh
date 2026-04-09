#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: scripts/sign-macos.sh <identity> <binary...>" >&2
  echo "example: scripts/sign-macos.sh 'Developer ID Application: Your Name (TEAMID)' dist/v0.2.0/ffast-darwin-arm64" >&2
  exit 1
fi

IDENTITY="$1"
shift

for bin in "$@"; do
  echo "signing $bin"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$bin"
  echo "verifying codesign $bin"
  codesign --verify --verbose=2 "$bin"
  echo "assessing with spctl $bin"
  spctl --assess --type execute --verbose "$bin"
done

echo "signing complete"
