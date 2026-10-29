#!/bin/sh
set -eu

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
APP_DIR="$ROOT_DIR/Orchard.app"
BINARY="$ROOT_DIR/.build/release/orchard"
: "${ORCHARD_SIGNING_IDENTITY:?Set ORCHARD_SIGNING_IDENTITY to a stable signing certificate before packaging}"
if [ "$ORCHARD_SIGNING_IDENTITY" = "-" ]; then
    echo "Use a stable signing certificate so Accessibility grants survive app updates." >&2
    exit 2
fi

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BINARY" "$APP_DIR/Contents/MacOS/orchard"
chmod +x "$APP_DIR/Contents/MacOS/orchard"
COMMIT=$(git rev-parse --verify HEAD)
/usr/libexec/PlistBuddy -c "Add OrchardBuildCommit string $COMMIT" "$APP_DIR/Contents/Info.plist"
/bin/sh "$ROOT_DIR/Scripts/sign-app.sh" "$APP_DIR"

echo "$APP_DIR"
