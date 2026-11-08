#!/bin/bash
# Notarizes and staples build/Harmune.app. It must be signed with a Developer
# ID Application certificate.
#
#   Scripts/notarize.sh <keychain-profile>
#
# Create the profile once. This stores your credentials in your keychain:
#   xcrun notarytool store-credentials <keychain-profile>
set -euo pipefail

cd "$(dirname "$0")/.."
PROFILE="${1:?usage: Scripts/notarize.sh <keychain-profile>}"
APP=build/Harmune.app

# Capture first: with pipefail, grep -q exiting early fails the pipeline.
signature="$(codesign -dvv "$APP" 2>&1)"
if ! grep -q '^Authority=Developer ID Application' <<<"$signature"; then
    echo "$APP isn't signed with a Developer ID Application certificate." >&2
    exit 1
fi

ZIP=build/Harmune-notarize.zip
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
spctl -a -vv "$APP"
