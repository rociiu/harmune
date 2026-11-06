#!/bin/bash
# Render the release cask to stdout. Run after Scripts/package.sh.
# Usage: Scripts/render-cask.sh <github-owner/repo> <vX.Y.Z>
set -euo pipefail

cd "$(dirname "$0")/.."
repo="${1:-}"
tag="${2:-}"
if [[ ! "$repo" =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$ || ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <github-owner/repo> <vX.Y.Z>" >&2
    exit 64
fi

version="${tag#v}"
archive="build/release/Harmune-$version-arm64.zip"
if [ ! -f "$archive" ]; then
    echo "$archive not found. Package the matching Apple Silicon release first." >&2
    exit 1
fi

sha="$(shasum -a 256 "$archive")"
sed -e '/^# Template/d' \
    -e "s|@VERSION@|$version|g" \
    -e "s|@SHA256@|${sha%% *}|g" \
    -e "s|@REPOSITORY@|$repo|g" \
    Casks/harmune.rb
