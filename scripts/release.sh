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
    # Auto-increment version: patch 0-9, then bump minor and reset patch.
    # e.g. 1.3.9 → 1.4.0, 1.9.9 → 2.0.0
    LAST_VERSION="${LAST_TAG#ppu-v}"
    MAJOR=$(echo "$LAST_VERSION" | cut -d. -f1)
    MINOR=$(echo "$LAST_VERSION" | cut -d. -f2)
    PATCH=$(echo "$LAST_VERSION" | cut -d. -f3)
    PATCH=$((PATCH + 1))
    if [ "$PATCH" -gt 9 ]; then
        PATCH=0
        MINOR=$((MINOR + 1))
    fi
    if [ "$MINOR" -gt 9 ]; then
        MINOR=0
        MAJOR=$((MAJOR + 1))
    fi
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

# --- Pull latest from origin and upstream ---
echo "==> Pulling latest from origin..."
git pull origin main --ff-only 2>/dev/null || {
    echo "Error: fast-forward pull from origin/main failed."
    echo "       Your local branch has diverged. Merge or rebase manually first."
    exit 1
}

echo "==> Fetching upstream..."
git fetch upstream main 2>/dev/null || {
    echo "Warning: could not fetch upstream (network issue?). Continuing with local state."
}

if [ "$(git rev-parse HEAD)" != "$(git merge-base HEAD upstream/main 2>/dev/null)" ] && \
   git merge-base --is-ancestor HEAD upstream/main 2>/dev/null; then
    # We're behind upstream — try a clean merge
    echo "==> Merging upstream/main..."
    if ! git merge upstream/main --no-edit; then
        git merge --abort
        echo "Error: upstream merge has conflicts. Resolve manually before releasing."
        exit 1
    fi
    git push origin main
    echo "==> Upstream merged and pushed."
elif ! git merge-base --is-ancestor upstream/main HEAD 2>/dev/null; then
    # We have diverged from upstream — try merge
    echo "==> Merging upstream/main (diverged)..."
    if ! git merge upstream/main --no-edit; then
        git merge --abort
        echo "Error: upstream merge has conflicts. Resolve manually before releasing."
        exit 1
    fi
    git push origin main
    echo "==> Upstream merged and pushed."
else
    echo "==> Already up to date with upstream."
fi

# Push main to origin before building
echo "==> Pushing main to origin..."
git push origin main

# Check if tag already exists
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Error: tag ${TAG} already exists."
    exit 1
fi

# --- Build GhosttyKit (Zig) ---
# zig 0.15.2's linker can't use the macOS 26.4+ SDK stubs (Apple dropped the
# arm64-macos target from the .tbd files, leaving only arm64e), which makes
# every libSystem symbol come up undefined. The shim answers zig's SDK query
# with the older 15.4 SDK and passes all other xcrun calls through. Remove
# once zig ships the fix (Codeberg ziglang/zig PR #31673).
if [ -d "$HOME/.config/zig/sdk-shim" ]; then
    export PATH="$HOME/.config/zig/sdk-shim:$PATH"
fi

# The xcframework's iOS slice needs the full Xcode toolchain, not the
# Command Line Tools (zig's findNative fails with DarwinSdkNotFound
# otherwise). Xcode-beta is the only Xcode installed on this machine.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode-beta.app" ]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app"
fi

echo "==> Building GhosttyKit..."
zig build \
    -Doptimize=ReleaseFast \
    -Demit-macos-app=false \
    -Dversion-string="${VERSION}"

# --- Build macOS app ---
rm -rf macos/build/Release/Ghostty.app macos/build/Release/"Ghostty Pro Plus Ultra.app"
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
# Resolve sign_update from Xcode's SPM-managed Sparkle package (no temp files)
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData/Ghostty-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update -maxdepth 0 2>/dev/null | head -1)
if [ -z "$SIGN_UPDATE" ] || [ ! -x "$SIGN_UPDATE" ]; then
    echo "ERROR: Sparkle sign_update not found in Xcode DerivedData."
    echo "       Build the project in Xcode first so SPM resolves the Sparkle package."
    exit 1
fi
SPARKLE_SIG=$("$SIGN_UPDATE" "$DMG_NAME")
if [ -z "$SPARKLE_SIG" ]; then
    echo "ERROR: sign_update returned empty signature"
    exit 1
fi
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
