#!/bin/sh
set -eu

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
INSTALL_DIR=${ORCHARD_INSTALL_DIR:-"$HOME/.local/bin"}

cd "$ROOT_DIR"
swift build -c release

mkdir -p "$INSTALL_DIR"
# Replace by rename so runs already executing the old binary keep working.
cp "$ROOT_DIR/.build/release/orchard" "$INSTALL_DIR/.orchard.new"
mv -f "$INSTALL_DIR/.orchard.new" "$INSTALL_DIR/orchard"

echo "$INSTALL_DIR/orchard"
