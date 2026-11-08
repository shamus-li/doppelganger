#!/bin/bash
# Builds upstream sshfs against macFUSE's libfuse3, applying the patches in sshfs/patches.
#
#   sshfs/build.sh [OUTPUT]      (default: build/sshfs/sshfs)
#
# Needs macFUSE 5, and meson, ninja, pkgconf and glib from Homebrew.
set -euo pipefail
VERSION=3.7.6
SHA256=6a1bcb31450a077e9cb1b7ff158c71de34db697c3c0da6cb362502131e495893
URL=https://github.com/libfuse/sshfs/releases/download/sshfs-$VERSION/sshfs-$VERSION.tar.xz

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/../build/sshfs/sshfs}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/sshfs.tar.xz" "$URL"
echo "$SHA256  $WORK/sshfs.tar.xz" | shasum -a 256 -c --quiet
tar -xf "$WORK/sshfs.tar.xz" -C "$WORK"
SRC=$WORK/sshfs-$VERSION
shopt -s nullglob
# The patches build on each other in this order; any that no longer fits exactly stops the build.
for patch in "$HERE"/patches/*.patch; do patch -s --fuzz=0 -d "$SRC" -p1 <"$patch"; done

# macFUSE installs its pkg-config file outside Homebrew's search path.
PKG_CONFIG_PATH=/usr/local/lib/pkgconfig meson setup "$WORK/build" "$SRC" >/dev/null
ninja --quiet -C "$WORK/build" sshfs

mkdir -p "$(dirname "$OUT")"
cp "$WORK/build/sshfs" "$OUT"
"$OUT" -V 2>&1 | grep version
