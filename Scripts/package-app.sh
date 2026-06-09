#!/bin/sh
set -eu

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
APP_DIR="$ROOT_DIR/DevRunner.app"
BINARY="$ROOT_DIR/.build/release/dev-runner"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BINARY" "$APP_DIR/Contents/MacOS/dev-runner"
chmod +x "$APP_DIR/Contents/MacOS/dev-runner"

echo "$APP_DIR"
