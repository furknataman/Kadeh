#!/bin/bash
#
# release.sh
#
# This file is part of Whisky.
#
# Whisky is free software: you can redistribute it and/or modify it under the terms
# of the GNU General Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with Whisky.
# If not, see https://www.gnu.org/licenses/.
#
# Builds, signs, notarizes, staples, and packages Kadeh.app as a DMG, and writes
# the Sparkle appcast that announces it.
#
# Prerequisites:
#   - Developer ID Application certificate (team PY8XQ9L8AA) in the Keychain
#   - Sparkle's EdDSA key in the Keychain under the account "kadeh"
#     (generate_keys --account kadeh)
#   - notarytool credentials in the Keychain, never in the repo, stored once with
#     xcrun notarytool store-credentials kadeh-notary --key <p8> --key-id <id> --issuer <id>
#
# Usage: scripts/release.sh <version>
# Example: scripts/release.sh 3.7.0

set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
NOTARY_PROFILE="${NOTARY_PROFILE:-kadeh-notary}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/release"
ARCHIVE_PATH="$BUILD_DIR/Kadeh.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/Kadeh-$VERSION.dmg"
REPO_URL="https://github.com/furknataman/Kadeh"
# The commit count only grows on main, so every release outranks the last for Sparkle.
BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD)"
SPARKLE_BIN="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Whisky-*/SourcePackages/artifacts/sparkle/Sparkle/bin | head -1)"

cd "$PROJECT_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving Kadeh $VERSION ($BUILD_NUMBER)"
xcodebuild \
    -project Whisky.xcodeproj \
    -scheme Whisky \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    SKIP_SWIFTLINT_BUILD_PHASE=YES \
    archive

echo "==> Exporting and re-signing with Developer ID"
rm -rf "$EXPORT_PATH"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist scripts/exportOptions.plist

APP_PATH="$EXPORT_PATH/Kadeh.app"
[ -d "$APP_PATH" ] || { echo "Kadeh.app not found at $APP_PATH"; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Building DMG"
# The Applications link is what the user drags Kadeh onto.
DMG_ROOT="$BUILD_DIR/dmg"
rm -rf "$DMG_ROOT" "$DMG_PATH"
mkdir -p "$DMG_ROOT"
ditto "$APP_PATH" "$DMG_ROOT/Kadeh.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
    -volname "Kadeh" \
    -srcfolder "$DMG_ROOT" \
    -ov -format UDZO \
    "$DMG_PATH"

echo "==> Signing DMG"
codesign --sign "Developer ID Application: Furkan Ataman (PY8XQ9L8AA)" --timestamp "$DMG_PATH"

echo "==> Submitting to notary service (this can take several minutes)"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Verifying stapled DMG"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

echo "==> Writing appcast"
# Every release carries its own appcast; the app reads the newest release's.
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account kadeh "$DMG_PATH")"
cat > "$BUILD_DIR/appcast.xml" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Kadeh</title>
        <item>
            <title>Kadeh $VERSION</title>
            <sparkle:releaseNotesLink>$REPO_URL/releases/tag/v$VERSION</sparkle:releaseNotesLink>
            <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
            <enclosure url="$REPO_URL/releases/download/v$VERSION/Kadeh-$VERSION.dmg"
                       type="application/octet-stream"
                       $SIGNATURE/>
        </item>
    </channel>
</rss>
APPCAST
xmllint --noout "$BUILD_DIR/appcast.xml"

echo
echo "Build artifacts: $DMG_PATH"
echo "                 $BUILD_DIR/appcast.xml"
shasum -a 256 "$DMG_PATH"
echo
echo "Publish (the engine's Libraries.tar.gz and WhiskyWineVersion.plist come from"
echo "scripts/assemble-engine.py; every release must carry the plist and the appcast):"
echo "  gh release create v$VERSION --repo furknataman/Kadeh --title \"Kadeh $VERSION\" \\"
echo "    \"$DMG_PATH\" \"$BUILD_DIR/appcast.xml\" <engine-build>/WhiskyWineVersion.plist [<engine-build>/Libraries.tar.gz]"
