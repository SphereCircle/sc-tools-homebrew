#!/usr/bin/env bash
set -euo pipefail

REPO="SphereCircle/sc-tools-homebrew"

echo "🔍 Fetching latest tag for $REPO..."

LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/tags" | jq -r '.[0].name')

if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
    echo "❌ Could not determine latest tag."
    exit 1
fi

echo "✔ Latest tag: $LATEST_TAG"

TARBALL_URL="https://github.com/$REPO/archive/refs/tags/$LATEST_TAG.tar.gz"

echo "⬇ Downloading tarball:"
echo "   $TARBALL_URL"

curl -L "$TARBALL_URL" -o release.tar.gz

echo "🔐 Calculating SHA-256 checksum..."
SHA256=$(shasum -a 256 release.tar.gz | awk '{print $1}')

rm -f release.tar.gz

echo
echo "========================================"
echo " Homebrew Formula Values"
echo "========================================"
echo "url \"${TARBALL_URL}\""
echo "sha256 \"${SHA256}\""
echo "version \"${LATEST_TAG#v}\""
echo "========================================"
echo
echo "🎉 Done! Paste these into your formula."
