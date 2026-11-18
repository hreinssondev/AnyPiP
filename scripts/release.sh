#!/bin/bash
# Builds dist/AnyPIP.dmg: a Developer ID signed, notarized and stapled AnyPIP.app.
#
# Signing and notarization go through the Apple account signed into Xcode
# (Settings > Accounts) for the team below, so no local Developer ID certificate
# or notarytool credentials are needed.
#
# Requires: Xcode, `brew install create-dmg`.
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="8FB39RNRQQ"
DIST="dist"
ARCHIVE="$DIST/AnyPIP.xcarchive"
EXPORT="$DIST/export"
STAGING="$DIST/dmg"
APP="$EXPORT/AnyPIP.app"
DMG="$DIST/AnyPIP.dmg"
NOTARIZATION_TIMEOUT=1800

command -v create-dmg >/dev/null || { echo "create-dmg not found: brew install create-dmg" >&2; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Archiving"
xcodebuild archive \
    -project AnyPIP.xcodeproj \
    -scheme AnyPIP \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    -quiet

cat > "$DIST/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
EOF

echo "==> Signing with Developer ID and uploading for notarization"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$DIST/ExportOptions.plist" \
    -exportPath "$EXPORT" \
    -allowProvisioningUpdates

echo "==> Waiting for notarization"
deadline=$((SECONDS + NOTARIZATION_TIMEOUT))
until xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$EXPORT" > "$DIST/notarization.log" 2>&1; do
    if ((SECONDS >= deadline)); then
        echo "Notarization did not finish within $((NOTARIZATION_TIMEOUT / 60)) minutes. Last output:" >&2
        cat "$DIST/notarization.log" >&2
        exit 1
    fi
    sleep 30
done

xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Building DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/AnyPIP.app"
create-dmg \
    --volname "AnyPIP" \
    --background scripts/dmg-background.png \
    --window-pos 200 120 \
    --window-size 600 600 \
    --icon-size 128 \
    --text-size 16 \
    --icon "AnyPIP.app" 150 253 \
    --app-drop-link 450 253 \
    --no-internet-enable \
    "$DMG" "$STAGING"

echo "==> Done: $DMG ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"))"
