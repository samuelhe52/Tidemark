#!/bin/bash
#
# Build a Developer ID signed, notarized Tidemark DMG on this Mac.
#
# Signing uses the Developer ID Application identity in the keychain. Notarization
# uses a `notarytool` keychain profile. No Xcode account sign-in is needed.
#
# Output: build/release/Tidemark-<version>.dmg and its .sha256.
#
# Environment:
#   NOTARY_PROFILE  Required. An `xcrun notarytool store-credentials` profile. The app
#                   and the DMG are both notarized and stapled.
#   VERSION         Marketing version. Defaults to MARKETING_VERSION in the project.
#   BUILD_NUMBER    CFBundleVersion. Defaults to the project's CURRENT_PROJECT_VERSION.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Tidemark.xcodeproj"
SCHEME="Tidemark"
APP_NAME="Tidemark"
TEAM_ID="768QBKMWKW"

project_setting() {
  awk -F' = ' -v key="$1" '$1 ~ key { gsub(/[;"]/, "", $2); print $2; exit }' "$PROJECT/project.pbxproj"
}

VERSION="${VERSION:-$(project_setting MARKETING_VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(project_setting CURRENT_PROJECT_VERSION)}"

OUT="build/release"
ARCHIVE="$OUT/$APP_NAME.xcarchive"
APP="$OUT/export/$APP_NAME.app"
APP_ZIP="$OUT/$APP_NAME.zip"
DMG="$OUT/$APP_NAME-$VERSION.dmg"

log() { printf '\n==> %s\n' "$*"; }
pretty() { if command -v xcbeautify >/dev/null; then xcbeautify --disable-logging; else cat; fi; }

command -v create-dmg >/dev/null || {
  echo "create-dmg is required. Install it with: npm install --global create-dmg" >&2
  exit 1
}
[[ -n "${NOTARY_PROFILE:-}" ]] || {
  echo "Set NOTARY_PROFILE to a notarytool keychain profile so the app and DMG are notarized." >&2
  exit 1
}

log "Archiving $APP_NAME $VERSION ($BUILD_NUMBER)"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  | pretty

cat >"$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF

log "Signing with Developer ID"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" \
  | pretty

log "Notarizing the app"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$APP_ZIP"

xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')"
[[ -n "$IDENTITY" ]] || { echo "The exported app is not signed with Developer ID." >&2; exit 1; }

log "Creating $DMG"
create-dmg "$APP" "$OUT" --no-version-in-filename --identity="$IDENTITY"
mv "$OUT/$APP_NAME.dmg" "$DMG"
codesign --verify --verbose=2 "$DMG"

log "Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")

log "Done: $DMG"
