#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-${FFAST_VERSION:-}}"
if [ -z "$VERSION" ]; then
  VERSION="$(git describe --tags --exact-match 2>/dev/null || true)"
fi
if [ -z "$VERSION" ]; then
  echo "error: provide version argument, e.g. scripts/build-release.sh v0.1.1" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist/$VERSION"

mkdir -p "$DIST_DIR"

build_one() {
  local target="$1"
  local out_name="$2"
  echo "building $out_name ($target)"
  zig build -Doptimize=ReleaseFast -Dtarget="$target" --prefix "$DIST_DIR/.prefix-$out_name"
  cp "$DIST_DIR/.prefix-$out_name/bin/ffast" "$DIST_DIR/$out_name"
  chmod +x "$DIST_DIR/$out_name"
}

build_one aarch64-macos "ffast-darwin-arm64"
build_one x86_64-macos "ffast-darwin-x86_64"
build_one aarch64-linux-gnu "ffast-linux-arm64"
build_one x86_64-linux-gnu "ffast-linux-x86_64"

cp "$ROOT_DIR/install/install.sh" "$DIST_DIR/install.sh"
chmod +x "$DIST_DIR/install.sh"

(
  cd "$DIST_DIR"
  rm -f checksums.txt
  for file in ffast-darwin-arm64 ffast-darwin-x86_64 ffast-linux-arm64 ffast-linux-x86_64 install.sh; do
    shasum -a 256 "$file" >> checksums.txt
  done
)

echo "release artifacts written to $DIST_DIR"
