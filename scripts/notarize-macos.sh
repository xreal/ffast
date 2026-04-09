#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: scripts/notarize-macos.sh <notary-profile> <binary...>" >&2
  echo "example: scripts/notarize-macos.sh ffast-notary dist/v0.2.0/ffast-darwin-arm64" >&2
  exit 1
fi

PROFILE="$1"
shift

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for bin in "$@"; do
  name="$(basename "$bin")"
  zip_path="$TMP_DIR/$name.zip"

  echo "creating zip for notarization: $name"
  /usr/bin/ditto -c -k --keepParent "$bin" "$zip_path"

  echo "submitting notarization: $name"
  xcrun notarytool submit "$zip_path" --keychain-profile "$PROFILE" --wait

  echo "stapling notarization ticket: $name"
  xcrun stapler staple "$bin"
  xcrun stapler validate "$bin"
done

echo "notarization complete"
