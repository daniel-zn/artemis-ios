#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Archives a Release build and uploads it to App Store Connect for TestFlight.
#
#   ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> [ASC_KEY_P8=<key contents>] Scripts/testflight.sh [--validate-only]
#
# Needs an App Store Connect API key (role App Manager or Admin): its contents in ASC_KEY_P8, or its
# .p8 file at ~/.appstoreconnect/private_keys/AuthKey_<id>.p8. The archive signs automatically with
# the key (development); the export signs manually, because an App Manager key can't use
# cloud-managed distribution certificates. It needs an "Apple Distribution" identity in the login
# keychain and the App Store profile "Artemis App Store" installed (`Scripts/asc.py profile` makes
# and installs it; it expires with the certificate, then run that again).
# Run it in a logged-in session: the login keychain is locked elsewhere (e.g. over SSH).
# The app is called Artemis; the Xcode target and the built Moonlight.app keep upstream's name.
# xcodebuild resolves the OpenSSL package with the system git (-scmProvider system), and without the
# keychain (-packageAuthorizationProvider netrc): its github.com lookup for the binary artifact waits
# forever while the Mac is locked.
# The build number is the commit count, so every upload from a new commit is higher than the last.
# --validate-only signs the export and checks every bundle in it without uploading.
# The app signs with Signing/Artemis.entitlements (the target's CODE_SIGN_ENTITLEMENTS): the multicast
# entitlement Apple granted, so Wake-on-LAN can broadcast. The export checks it's in the signed app.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
if [[ -n "${ASC_KEY_P8:-}" && ! -f "$KEY" ]]; then
  # The key's contents came from `secret run`: a private temp file for this run only.
  KEYDIR="$(mktemp -d)"; chmod 700 "$KEYDIR"; trap 'rm -rf "$KEYDIR"' EXIT
  KEY="$KEYDIR/AuthKey_${ASC_KEY_ID}.p8"
  (umask 077; printf '%s\n' "$ASC_KEY_P8" > "$KEY")
fi
[[ -f "$KEY" ]] || { echo "No API key at $KEY"; exit 1; }
DESTINATION=upload
[[ "${1:-}" == "--validate-only" ]] && DESTINATION=export

BUNDLE=com.danielzn.artemis
BUILD=$(git rev-list --count HEAD)
OUT=build/testflight
rm -rf "$OUT" && mkdir -p "$OUT"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "Archiving build $BUILD…"
xcodebuild archive -project Moonlight.xcodeproj -scheme Moonlight -scmProvider system -packageAuthorizationProvider netrc -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/Artemis.xcarchive" -derivedDataPath "$OUT/dd" \
  CURRENT_PROJECT_VERSION="$BUILD" DEVELOPMENT_TEAM=6G4QGZ2Q95 CODE_SIGN_STYLE=Automatic \
  "${AUTH[@]}" > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; exit 1; }

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>6G4QGZ2Q95</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$BUNDLE</key><string>Artemis App Store</string>
  </dict>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

APP_IN_ARCHIVE="$OUT/Artemis.xcarchive/Products/Applications/Moonlight.app"
# The UI font (Orbix, Artemis/Fonts) and its license ship in the app
for file in Orbix-Regular.otf OFL.txt; do
  [[ -f "$APP_IN_ARCHIVE/$file" ]] || { echo "FAIL: $file isn't in the app"; exit 1; }
done
echo "The app contains the Orbix font and its license"
# Uploads too: the archived app carries the multicast entitlement (the export below checks it again)
[[ "$(codesign -d --entitlements - --xml "$APP_IN_ARCHIVE" 2>/dev/null | plutil -extract 'com\.apple\.developer\.networking\.multicast' raw - 2>/dev/null)" == true ]] \
  || { echo "FAIL: the multicast entitlement isn't in the archived app"; exit 1; }

echo "Exporting ($DESTINATION)…"
xcodebuild -exportArchive -archivePath "$OUT/Artemis.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" "${AUTH[@]}" > "$OUT/export.log" 2>&1 || { tail -30 "$OUT/export.log"; exit 1; }
rm -rf "$OUT/dd"
if [[ "$DESTINATION" == upload ]]; then
  echo "Uploaded build $BUILD. TestFlight shows it once Apple has processed it (usually 5–30 minutes)."
  exit 0
fi

# What the App Store build is signed with: every bundle (the app and any embedded
# frameworks) by Apple Distribution for the team, and the app's entitlements without get-task-allow.
unzip -q -o "$OUT/export/Moonlight.ipa" -d "$OUT/ipa"
APP="$OUT/ipa/Payload/Moonlight.app"
fail() { echo "FAIL: $*"; exit 1; }
for bundle in "$APP" "$APP"/Frameworks/*.framework; do
  info=$(codesign -dvv "$bundle" 2>&1)
  grep -q '^Authority=Apple Distribution' <<<"$info" || fail "$bundle is not signed by Apple Distribution"
  grep -q '^TeamIdentifier=6G4QGZ2Q95' <<<"$info" || fail "$bundle has the wrong team"
  codesign --verify --strict "$bundle" || fail "$bundle signature doesn't verify"
  echo "ok  $(basename "$bundle")"
done
codesign -d --entitlements - --xml "$APP" 2>/dev/null > "$OUT/entitlements.plist"
plutil -p "$OUT/entitlements.plist"
grep -q "<string>6G4QGZ2Q95.$BUNDLE</string>" "$OUT/entitlements.plist" || fail "application-identifier"
[[ "$(plutil -extract 'com\.apple\.developer\.networking\.multicast' raw "$OUT/entitlements.plist" 2>/dev/null)" == true ]] \
  || fail "the multicast entitlement isn't in the signed app"
[[ "$(plutil -extract get-task-allow raw "$OUT/entitlements.plist" 2>/dev/null || echo false)" == false ]] \
  || fail "get-task-allow is true (a development signature)"
security cms -D -i "$APP/embedded.mobileprovision" > "$OUT/profile.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Name' "$OUT/profile.plist")" == "Artemis App Store" ]] || fail "profile"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")" == "$BUILD" ]] || fail "build number"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$APP/Info.plist")" == "false" ]] \
  || fail "ITSAppUsesNonExemptEncryption"
echo "Signed for App Store distribution, build $BUILD: $OUT/export (not uploaded)."
