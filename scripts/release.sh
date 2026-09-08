#!/bin/bash
#
# Builds a signed, notarized, stapled DMG ready for public download.
#
#   ./scripts/release.sh
#
# Prerequisites, both one-time:
#   1. A "Developer ID Application" certificate in your keychain.
#      Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application
#   2. A stored notarization credential:
#      xcrun notarytool store-credentials doubleshot-notary \
#          --apple-id <you@example.com> --team-id <TEAMID>
set -euo pipefail

TEAM_ID="${TEAM_ID:-YWNTFJ7ZP3}"
NOTARY_PROFILE="${NOTARY_PROFILE:-doubleshot-notary}"
VOLNAME="DoubleShot for Claude Code"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/DoubleShot.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/DoubleShot.app"
DMG="$BUILD/DoubleShot.dmg"

step() { printf "\n==> %s\n" "$1"; }

IDENTITY="Developer ID Application: "
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "No 'Developer ID Application' certificate found in the keychain." >&2
    echo "Create one: Xcode → Settings → Accounts → Manage Certificates → + " >&2
    exit 1
fi
SIGNER=$(security find-identity -v -p codesigning \
    | grep -m1 "Developer ID Application: " \
    | sed 's/.*"\(.*\)".*/\1/')

step "Regenerating project"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null

step "Archiving"
rm -rf "$BUILD"
mkdir -p "$BUILD"
# Archive with AUTOMATIC signing only. Passing CODE_SIGN_IDENTITY here collides with
# automatic signing and fails with "conflicting provisioning settings"; the Developer
# ID re-signing happens during export instead.
xcodebuild -project DoubleShot.xcodeproj -scheme DoubleShot \
    -configuration Release -destination 'platform=macOS' \
    -archivePath "$ARCHIVE" archive \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
    >/dev/null

step "Exporting with Developer ID"
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>signingStyle</key><string>automatic</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT" -exportOptionsPlist "$BUILD/ExportOptions.plist" >/dev/null

step "Notarizing the app"
# The app is notarized and stapled on its own, not just inside the DMG. Stapling only
# the DMG leaves the app without a local ticket once it's copied out, so Gatekeeper has
# to reach Apple over the network — which fails offline or behind a restrictive proxy.
ditto -c -k --keepParent "$APP" "$BUILD/DoubleShot-app.zip"
xcrun notarytool submit "$BUILD/DoubleShot-app.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

step "Building DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

step "Signing the DMG"
# Notarizing a DMG is not enough on its own: an unsigned container makes spctl report
# "rejected — no usable signature" even when everything inside is fine.
codesign --force --sign "$SIGNER" --timestamp "$DMG"

step "Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

step "Verifying"
spctl -a -vvv -t open --context context:primary-signature "$DMG"
MP=$(hdiutil attach -nobrowse -readonly "$DMG" | grep -o '/Volumes/.*' | head -1)
spctl -a -vvv -t exec "$MP/DoubleShot.app"
codesign --verify --deep --strict --verbose=2 "$MP/DoubleShot.app"
hdiutil detach "$MP" >/dev/null

printf "\n==> Done: %s\n" "$DMG"
