#!/bin/bash
# Builds and signs build/Harmune.app: the MusicKit host, with the harmune CLI
# inside it so the CLI always finds this host.
#
#   Scripts/build-host.sh [--profile <file>] [--debug]
#
#   --profile <file>   Embed a provisioning profile and add the entitlements it
#                      grants. See docs/PHASE0_SETUP.md for when this is needed.
#   --debug            Build the debug configuration.
#   --universal        Build for both Apple silicon and Intel.
#
# Environment:
#   HARMUNE_BUNDLE_ID      Bundle ID (default: com.orinbyte.harmune)
#   HARMUNE_SIGN_IDENTITY  Signing identity. Default: a Developer ID Application
#                          certificate if there is one, otherwise Apple
#                          Development. "-" signs ad hoc, which can launch the
#                          host but won't get MusicKit access.
set -euo pipefail

cd "$(dirname "$0")/.."
BUNDLE_ID="${HARMUNE_BUNDLE_ID:-com.orinbyte.harmune}"
CONFIG=release
PROFILE=""
ARCHS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="${2:?--profile needs a file}"; shift 2 ;;
        --debug) CONFIG=debug; shift ;;
        --universal) ARCHS=(--arch arm64 --arch x86_64); shift ;;
        *) echo "Unknown option $1" >&2; exit 64 ;;
    esac
done

identity="${HARMUNE_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
    identities="$(security find-identity -v -p codesigning)"
    identity="$(sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' <<<"$identities" | head -1)"
    [ -n "$identity" ] || identity="$(sed -n 's/.*"\(Apple Development: .*\)"/\1/p' <<<"$identities" | head -1)"
    if [ -z "$identity" ]; then
        echo "No signing certificate found. Create one in Xcode > Settings > Accounts." >&2
        exit 1
    fi
fi

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product HarmuneHostApp
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product harmune
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

APP=build/Harmune.app
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/HarmuneHostApp" "$APP/Contents/MacOS/Harmune"
cp "$BIN/harmune" "$APP/Contents/Resources/bin/harmune"
VERSION="$(sed -n 's/.*static let current = "\(.*\)"/\1/p' Sources/HarmuneCore/Paths.swift)"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" \
    Apps/HarmuneHost/Info.plist > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

# App Sandbox stays off, because playback is reported to fail inside it.
ENTITLEMENTS="$(mktemp -t harmune-entitlements)"
trap 'rm -f "$ENTITLEMENTS" "$ENTITLEMENTS.profile"' EXIT
plutil -create xml1 "$ENTITLEMENTS"

if [ -n "$PROFILE" ]; then
    security cms -D -i "$PROFILE" > "$ENTITLEMENTS.profile"
    APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$ENTITLEMENTS.profile")"
    TEAM="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$ENTITLEMENTS.profile")"
    if [ "$APP_ID" != "$TEAM.$BUNDLE_ID" ]; then
        echo "The profile is for $APP_ID, but this build is $TEAM.$BUNDLE_ID." >&2
        exit 1
    fi
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    plutil -insert com\\.apple\\.application-identifier -string "$APP_ID" "$ENTITLEMENTS"
    plutil -insert com\\.apple\\.developer\\.team-identifier -string "$TEAM" "$ENTITLEMENTS"
fi

SIGN=(codesign --force --options runtime)
case "$identity" in
    "Developer ID Application:"*) SIGN+=(--timestamp) ;;
    *) SIGN+=(--timestamp=none) ;;
esac

echo "==> Signing with: $identity"
"${SIGN[@]}" --sign "$identity" --identifier "$BUNDLE_ID.cli" "$APP/Contents/Resources/bin/harmune"
"${SIGN[@]}" --sign "$identity" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo
echo "Built $APP ($BUNDLE_ID)"
echo "Profile: ${PROFILE:-none}"
echo "Next: Scripts/validate-phase0.sh (with Music.app quit)"
