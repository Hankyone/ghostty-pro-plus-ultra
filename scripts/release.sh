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

# Check the notarization credential before doing anything expensive.
#
# Notarization happens after the Zig build, the Xcode build, signing and DMG
# creation — a quarter of an hour in. A missing keychain profile used to fail
# there, having already pushed main, which is a miserable way to find out.
#
# This only ever warns. The check asks Apple, and Apple throttles: it has
# refused three times in a row while the credential was perfectly good and
# ordinary traffic kept flowing. A guard that exists to save you fifteen
# minutes is not worth blocking a release it cannot actually disprove, so a
# failure here says so and carries on. Notarization itself will fail plainly
# enough if the credential really is wrong.
if ! xcrun notarytool history --keychain-profile "notarytool-profile" >/dev/null 2>&1; then
    echo "Warning: could not verify the notarization credential."
    echo "         Apple may be throttling, or the profile may be missing."
    echo "         Continuing; notarization will say for certain. If it does"
    echo "         turn out to be the credential, recreate it with:"
    echo
    echo "  xcrun notarytool store-credentials notarytool-profile \\"
    echo "      --apple-id ${APPLE_ID} --team-id ${TEAM_ID}"
    echo
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
# Zig 0.16 fixed the Mach-O linker issue with newer SDK .tbd stubs, but
# @cImport still chokes on the Xcode 26.4+/27 macOS headers (mach_msg_*
# types become opaque and size assertions fail). Prefer the local xcrun
# shim that answers SDK queries with MacOSX15.4 when present.
if [ -d "${HOME}/.config/zig/sdk-shim" ]; then
    export PATH="${HOME}/.config/zig/sdk-shim:$PATH"
fi

if command -v brew >/dev/null 2>&1; then
    RELEASE_ZIG_PREFIX=$(brew --prefix zig 2>/dev/null || true)
    if [ -x "${RELEASE_ZIG_PREFIX}/bin/zig" ]; then
        export PATH="${RELEASE_ZIG_PREFIX}/bin:$PATH"
    fi
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

# Sign Sparkle components if present.
#
# Every one of these needs a secure timestamp, same as the keeper: they are
# separate bundles that notarization judges on their own terms. And none of
# them may fail quietly. Xcode leaves them ad-hoc signed, so a swallowed
# failure here does not leave the previous signature in place, it leaves no
# real signature at all — and the first sign of it is a rejected notarization
# a quarter of an hour later, blamed on the wrong thing.
#
# The timestamp needs Apple reachable, so this is also where a flaky network
# shows up. Better it stops here, loudly.
if [ -d "${APP}/Contents/Frameworks/Sparkle.framework" ]; then
    SPARKLE="${APP}/Contents/Frameworks/Sparkle.framework/Versions/B"
    for component in \
        "$SPARKLE/XPCServices/Downloader.xpc" \
        "$SPARKLE/XPCServices/Installer.xpc" \
        "$SPARKLE/Autoupdate" \
        "$SPARKLE/Updater.app" \
        "${APP}/Contents/Frameworks/Sparkle.framework"
    do
        [ -e "$component" ] || continue
        signed=false
        for delay in 0 45 120; do
            [ "$delay" -gt 0 ] && sleep "$delay"
            if /usr/bin/codesign --verbose -f -s "$CERT_NAME" -o runtime --timestamp \
                "$component"; then
                signed=true
                break
            fi
        done
        if [ "$signed" = false ]; then
            echo "Error: could not sign $(basename "$component")."
            echo
            echo "This is almost always Apple's timestamp service throttling,"
            echo "not a broken credential and not your connection: ordinary"
            echo "traffic to Apple keeps working while it refuses. Repeated"
            echo "release attempts are what provoke it. Leave it a few minutes"
            echo "and run this again."
            exit 1
        fi
    done
fi

# Sign the per-pane keeper.
#
# It's a Mach-O executable living under Resources, which the app's own
# signature does not cover, so notarization judges it on its own terms and
# wants all three of Developer ID, hardened runtime and a secure timestamp.
# Signing has to happen before the app itself, inside out.
KEEPER="${APP}/Contents/Resources/ghostty/ghostty-keeper"
if [ -f "$KEEPER" ]; then
    /usr/bin/codesign --verbose -f -s "$CERT_NAME" -o runtime --timestamp \
        "$KEEPER"
else
    echo "Error: ghostty-keeper is missing from the bundle."
    echo "       Panes can't start without it. Aborting rather than shipping."
    exit 1
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

# create-dmg 1.3+ takes <output.dmg> <source_folder>, and --codesign instead of --identity.
DMG_STAGE=$(mktemp -d)
trap 'rm -rf "$DMG_STAGE"' EXIT
cp -R "$APP" "$DMG_STAGE/"
npx create-dmg \
    --volname "Ghostty Pro Plus Ultra" \
    --app-drop-link 425 185 \
    --codesign "$CERT_NAME" \
    --overwrite \
    "$ROOT_DIR/$DMG_NAME" \
    "$DMG_STAGE"
rm -rf "$DMG_STAGE"
trap - EXIT

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
    # Force local gh-pages to match the remote before regenerating, so a
    # stale local branch can't produce a non-fast-forward push. The appcast
    # is fully regenerated below, so resetting to remote loses nothing.
    git checkout -B gh-pages origin/gh-pages
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
