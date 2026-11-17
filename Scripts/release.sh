#!/bin/sh
# Usage: Scripts/release.sh <version>   (e.g. 0.2.0)
set -eu

VERSION=${1:?usage: Scripts/release.sh <version>}
TAG="v$VERSION"
REPO=${ORCHARD_REPO:-kyoya1123/Orchard}
TAP_REPO=${ORCHARD_TAP_REPO:-kyoya1123/homebrew-tap}
TARBALL_URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

git fetch --quiet origin main --tags
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "Release from a clean checkout of origin/main." >&2
  exit 1
fi
if ! grep -qx "let orchardVersion = \"$VERSION\"" Sources/OrchardCLI/Version.swift; then
  echo "Bump orchardVersion in Sources/OrchardCLI/Version.swift to $VERSION on main first." >&2
  exit 1
fi
if git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null; then
  echo "$TAG already exists." >&2
  exit 1
fi

swift test

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
gh repo clone "$TAP_REPO" "$WORK_DIR/tap" -- --quiet
FORMULA="$WORK_DIR/tap/Formula/orchard.rb"
if ! grep -q '^  url "' "$FORMULA" || ! grep -q '^  sha256 "' "$FORMULA"; then
  echo "$TAP_REPO has no Formula/orchard.rb with url and sha256 lines." >&2
  exit 1
fi

git tag -a "$TAG" -m "$TAG"
git push origin "refs/tags/$TAG"
gh release create "$TAG" --repo "$REPO" --title "$TAG" --generate-notes --verify-tag

curl -fsSL "$TARBALL_URL" -o "$WORK_DIR/source.tar.gz"
SHA256=$(shasum -a 256 "$WORK_DIR/source.tar.gz" | cut -d ' ' -f 1)

sed -E -i '' \
  -e "s|^  url \".*\"$|  url \"$TARBALL_URL\"|" \
  -e "s|^  sha256 \".*\"$|  sha256 \"$SHA256\"|" \
  "$FORMULA"
git -C "$WORK_DIR/tap" commit --quiet -am "orchard $VERSION"
git -C "$WORK_DIR/tap" push --quiet origin HEAD

echo "Released $TAG ($SHA256)"
