#!/bin/bash
#
# Build a Developer ID signed, notarized Tidemark DMG on this Mac.
#
# Signing and app notarization use the developer account signed in to Xcode
# (Settings > Accounts); no keys or passwords are needed.
#
# Output: build/release/Tidemark-<version>.dmg and its .sha256.
#
# Environment:
#   VERSION         Marketing version. Defaults to MARKETING_VERSION in the project.
#   BUILD_NUMBER    CFBundleVersion. Defaults to the project's CURRENT_PROJECT_VERSION.
#   NOTARY_PROFILE  Optional `xcrun notarytool store-credentials` profile. When set,
#                   the DMG itself is notarized and stapled as well. Without it the
#                   DMG is signed and the app inside is notarized and stapled.

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
APP="$OUT/notarized/$APP_NAME.app"
DMG="$OUT/$APP_NAME-$VERSION.dmg"

log() { printf '\n==> %s\n' "$*"; }
pretty() { if command -v xcbeautify >/dev/null; then xcbeautify --disable-logging; else cat; fi; }

command -v create-dmg >/dev/null || {
  echo "create-dmg is required. Install it with: npm install --global create-dmg" >&2
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
  -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  | pretty

cat >"$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF

log "Signing with Developer ID and submitting for notarization"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/submission" \
  -allowProvisioningUpdates \
  | pretty

log "Waiting for Apple to notarize the app"
for attempt in $(seq 1 60); do
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" \
    -allowProvisioningUpdates >"$OUT/notarized.log" 2>&1; then
    break
  fi
  if [[ "$attempt" == 60 ]]; then
    echo "The app was not notarized within 30 minutes. Last output:" >&2
    cat "$OUT/notarized.log" >&2
    exit 1
  fi
  sleep 30
done

xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')"
[[ -n "$IDENTITY" ]] || { echo "The exported app is not signed with Developer ID." >&2; exit 1; }

log "Creating $DMG"
create-dmg "$APP" "$OUT" --no-version-in-filename --identity="$IDENTITY"
mv "$OUT/$APP_NAME.dmg" "$DMG"
codesign --verify --verbose=2 "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  log "Notarizing the DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")

log "Done: $DMG"
