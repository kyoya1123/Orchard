#!/bin/sh
set -eu

APP_DIR=${1:?Usage: sign-app.sh /path/to/Orchard.app}
IDENTITY=${ORCHARD_SIGNING_IDENTITY:?Set ORCHARD_SIGNING_IDENTITY to a stable Apple Development or Developer ID Application certificate}
if [ "$IDENTITY" = "-" ]; then
    echo "Ad-hoc signing changes the app identity on rebuild and cannot preserve Accessibility grants." >&2
    exit 2
fi
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")
/usr/bin/codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_DIR"
