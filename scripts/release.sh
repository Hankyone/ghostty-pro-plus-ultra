#!/bin/bash
set -euo pipefail

REPO="Hankyone/ghostty-pro-plus-ultra"
CERT_NAME="Developer ID Application: Anouar Mansour (K32684A887)"
APPLE_ID="hankyone@gmail.com"
TEAM_ID="K32684A887"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# --- Determine version ---
LAST_TAG=$(git tag --list 'ppu-v*' | sort -V | tail -1)
if [ -z "$LAST_TAG" ]; then
    VERSION="0.1.0"
else
    # Auto-increment patch version
    LAST_VERSION="${LAST_TAG#ppu-v}"
    MAJOR=$(echo "$LAST_VERSION" | cut -d. -f1)
    MINOR=$(echo "$LAST_VERSION" | cut -d. -f2)
    PATCH=$(echo "$LAST_VERSION" | cut -d. -f3)
    PATCH=$((PATCH + 1))
    VERSION="${MAJOR}.${MINOR}.${PATCH}"
fi

# Allow override: ./scripts/release.sh 1.2.3
if [ "${1:-}" != "" ]; then
    VERSION="${1#v}"
    VERSION="${VERSION#ppu-v}"
fi

TAG="ppu-v${VERSION}"
echo "==> Releasing Ghostty Pro Plus Ultra ${TAG}"

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: uncommitted changes. Commit or stash first."
    exit 1
fi

# Check if tag already exists
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Error: tag ${TAG} already exists."
    exit 1
fi

# --- Build GhosttyKit (Zig) ---
echo "==> Building GhosttyKit..."
zig build \
    -Doptimize=ReleaseFast \
    -Demit-macos-app=false \
    -Dversion-string="${VERSION}"

# --- Build macOS app ---
echo "==> Building Ghostty.app..."
cd macos
xcodebuild -target Ghostty -configuration Release -quiet
cd "$ROOT_DIR"

APP_BUILD="macos/build/Release/Ghostty.app"
APP="macos/build/Release/Ghostty Pro Plus Ultra.app"
mv "$APP_BUILD" "$APP"
PLIST="${APP}/Contents/Info.plist"

# --- Update Info.plist ---
echo "==> Updating Info.plist..."
BUILD_NUM=$(git rev-list --count HEAD)
COMMIT=$(git rev-parse --short HEAD)
/usr/libexec/PlistBuddy -c "Set :GhosttyCommit ${COMMIT}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUM}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST"

# Remove SUEnableAutomaticChecks so Sparkle uses its default (true)
/usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "$PLIST" 2>/dev/null || true

# --- Codesign ---
echo "==> Codesigning..."

# Sign Sparkle components if present
if [ -d "${APP}/Contents/Frameworks/Sparkle.framework" ]; then
    /usr/bin/codesign --verbose -f -s "$CERT_NAME" -o runtime \
        "${APP}/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
    /usr/bin/codesign --verbose -f -s "$CERT_NAME" -o runtime \
        "${APP}/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
    /usr/bin/codesign --verbose -f -s "$CERT_NAME" -o runtime \
        "${APP}/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
    /usr/bin/codesign --verbose -f -s "$CERT_NAME" -o runtime \
        "${APP}/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
    /usr/bin/codesign --verbose -f -s "$CERT_NAME" -o runtime \
        "${APP}/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
fi

# Sign dock tile plugin
/usr/bin/codesign --verbose -f -s "$CERT_NAME" -o runtime \
    "${APP}/Contents/PlugIns/DockTilePlugin.plugin"

# Sign main app
/usr/bin/codesign --verbose -f -s "$CERT_NAME" -o runtime \
    --entitlements "macos/Ghostty.entitlements" "$APP"

# Verify
codesign --verify --deep --strict "$APP"
echo "==> Codesign verified."

# --- Create DMG ---
echo "==> Creating DMG..."
DMG_NAME="GhosttyProPlusUltra-${VERSION}.dmg"

# Clean up any previous DMG
rm -f "$DMG_NAME" ./Ghostty*.dmg

npx create-dmg \
    --identity="$CERT_NAME" \
    "$APP" \
    ./ 2>/dev/null || true

# create-dmg names the file based on the app name
mv ./"Ghostty Pro Plus Ultra"*.dmg "$DMG_NAME" 2>/dev/null || mv ./Ghostty*.dmg "$DMG_NAME" 2>/dev/null || true

if [ ! -f "$DMG_NAME" ]; then
    echo "Error: DMG creation failed."
    exit 1
fi

# --- Notarize ---
echo "==> Notarizing (this may take a few minutes)..."
xcrun notarytool submit "$DMG_NAME" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --keychain-profile "notarytool-profile" \
    --wait

xcrun stapler staple "$DMG_NAME"
xcrun stapler staple "$APP"
echo "==> Notarization complete."

# --- Sparkle appcast ---
echo "==> Generating Sparkle appcast..."
SPARKLE_SIG=$(/tmp/sparkle/bin/sign_update "$DMG_NAME" 2>/dev/null || echo "")
DMG_SIZE=$(stat -f%z "$DMG_NAME")
DMG_URL="https://github.com/${REPO}/releases/download/${TAG}/${DMG_NAME}"
RELEASE_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S %z")

cat > /tmp/appcast.xml << APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Ghostty Pro Plus Ultra</title>
    <link>https://hankyone.github.io/ghostty-pro-plus-ultra/appcast.xml</link>
    <description>Updates for Ghostty Pro Plus Ultra</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${RELEASE_DATE}</pubDate>
      <sparkle:version>${BUILD_NUM}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <enclosure
        url="${DMG_URL}"
        ${SPARKLE_SIG}
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
APPCAST_EOF

# --- Tag and push ---
echo "==> Tagging ${TAG}..."
git tag "$TAG"
git push origin "$TAG"

# --- Create GitHub Release ---
echo "==> Creating GitHub Release..."
gh release create "$TAG" \
    --repo "$REPO" \
    --title "Ghostty Pro Plus Ultra ${VERSION}" \
    --generate-notes \
    "$DMG_NAME"

# --- Publish appcast to gh-pages ---
echo "==> Publishing appcast..."
CURRENT_BRANCH=$(git branch --show-current)
git stash --include-untracked 2>/dev/null || true

git fetch origin gh-pages 2>/dev/null || true
if git rev-parse --verify origin/gh-pages >/dev/null 2>&1; then
    git checkout gh-pages
    cp /tmp/appcast.xml appcast.xml
    git add appcast.xml
    git commit -m "Update appcast for ${TAG}" || true
    git push origin gh-pages
else
    git checkout --orphan gh-pages
    git rm -rf . 2>/dev/null || true
    cp /tmp/appcast.xml appcast.xml
    git add appcast.xml
    git commit -m "Initial appcast for ${TAG}"
    git push origin gh-pages
fi

git checkout "$CURRENT_BRANCH"
git stash pop 2>/dev/null || true

# --- Cleanup ---
rm -f "$DMG_NAME"
echo ""
echo "==> Done! Released ${TAG}"
echo "    GitHub Release: https://github.com/${REPO}/releases/tag/${TAG}"
echo "    Appcast: https://hankyone.github.io/ghostty-pro-plus-ultra/appcast.xml"
