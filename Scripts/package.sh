#!/bin/bash
# Packages build/Harmune.app as a .zip and a .dmg, with SHA-256 checksums, in
# build/release. Build it first (Scripts/build-host.sh), and notarize it if the
# package is for anyone else (Scripts/notarize.sh).
#
#   Scripts/package.sh [--allow-unnotarized]
set -euo pipefail

cd "$(dirname "$0")/.."
APP=build/Harmune.app
OUT=build/release
ALLOW=no
[ "${1:-}" = "--allow-unnotarized" ] && ALLOW=yes

[ -d "$APP" ] || { echo "$APP not found. Run Scripts/build-host.sh first." >&2; exit 1; }
codesign --verify --deep --strict "$APP"

if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    if [ "$ALLOW" = no ]; then
        echo "$APP isn't notarized, so macOS would block it on other Macs." >&2
        echo "Run Scripts/notarize.sh, or pass --allow-unnotarized for a local test package." >&2
        exit 1
    fi
    echo "warning: packaging an app that isn't notarized" >&2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="Harmune-$VERSION-$(uname -m)"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> $OUT/$NAME.zip"
ditto -c -k --keepParent "$APP" "$OUT/$NAME.zip"

echo "==> $OUT/$NAME.dmg"
STAGE="$(mktemp -d -t harmune-dmg)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Harmune.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Harmune $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$OUT/$NAME.dmg"

(cd "$OUT" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS)
cat "$OUT/SHA256SUMS"
