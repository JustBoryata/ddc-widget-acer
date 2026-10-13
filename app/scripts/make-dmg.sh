#!/bin/zsh
# Builds the app and packages it as build/DDCWidget-<version>.dmg (drag to Applications).
# Signing: ad-hoc by default. Set SIGN_IDENTITY="Developer ID Application: ..." to sign for
# distribution, and NOTARY_PROFILE=<notarytool keychain profile> to notarize and staple.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/make-app.sh
APP="build/DDC Widget.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi

STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="build/DDCWidget-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "DDC Widget" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
echo "Built $DMG"
