#!/usr/bin/env bash
# project-standard v1.11 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Archives, signs and exports the iOS app of a Flutter part and uploads it to App Store Connect (TestFlight), signed with
# Xcode's automatic signing through the App Store Connect API key: xcodebuild -allowProvisioningUpdates with the key
# creates or downloads the certificates and profiles it needs, so a fresh macOS runner needs no certificate, profile or
# Xcode account (1.10). The same path runs on a Mac. The app-flutter release target calls it after
# `flutter build ios --config-only --release <store args>` (which writes the dart-defines and the version into
# ios/Flutter/Generated.xcconfig), inside `secrets.sh with-file appstore-api-key`, so the key is a mode-600 temp file:
#
#   store-ios.sh --key FILE --key-id ID --issuer ISSUER [--export-options PLIST] [--no-upload]
#
# Run in the part's folder. The ipa lands in build/ios/ipa, the archive in build/ios/archive/Runner.xcarchive. Without
# --export-options (the part's ios/ExportOptions.plist when it has one), the export is app-store-connect with automatic
# signing. The upload goes to App Store Connect, where the build shows in TestFlight; nothing is submitted for review.
# The key needs the Admin role in App Store Connect for xcodebuild to manage certificates (App Manager can upload only).

set -euo pipefail

key="" key_id="" issuer="" export_options="" upload=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --key) key=${2:-}; shift 2 ;;
    --key-id) key_id=${2:-}; shift 2 ;;
    --issuer) issuer=${2:-}; shift 2 ;;
    --export-options) export_options=${2:-}; shift 2 ;;
    --no-upload) upload=0; shift ;;
    *) echo "store-ios: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$key" ] && [ -f "$key" ] || { echo "store-ios: --key FILE (the App Store Connect .p8) is required" >&2; exit 2; }
[ -n "$key_id" ] && [ -n "$issuer" ] || { echo "store-ios: --key-id and --issuer are required (<part>_ASC_KEY_ID, <part>_ASC_ISSUER)" >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || { echo "store-ios: the iOS store build runs on a Mac (a macOS runner in CI)" >&2; exit 1; }
[ -d ios/Runner.xcworkspace ] || { echo "store-ios: no ios/Runner.xcworkspace here: run it in the Flutter part's folder" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# altool finds the key by its name AuthKey_<id>.p8 in API_PRIVATE_KEYS_DIR; xcodebuild takes the same file.
cp "$key" "$tmp/AuthKey_$key_id.p8"
chmod 600 "$tmp/AuthKey_$key_id.p8"
auth=(-allowProvisioningUpdates -authenticationKeyPath "$tmp/AuthKey_$key_id.p8" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")

if [ -z "$export_options" ]; then
  if [ -f ios/ExportOptions.plist ]; then
    export_options=ios/ExportOptions.plist
  else
    export_options="$tmp/ExportOptions.plist"
    cat >"$export_options" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
  fi
fi

archive=build/ios/archive/Runner.xcarchive
ipa_dir=build/ios/ipa
rm -rf "./$archive" "./$ipa_dir"
mkdir -p build/ios/archive

echo "store-ios: archive (automatic signing with the App Store Connect key $key_id)"
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" "${auth[@]}" archive

echo "store-ios: export with $export_options"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$ipa_dir" -exportOptionsPlist "$export_options" "${auth[@]}"

ipa=$(find "$ipa_dir" -maxdepth 1 -name '*.ipa' | sed -n 1p)
[ -n "$ipa" ] || { echo "store-ios: the export made no ipa in $ipa_dir" >&2; exit 1; }
echo "store-ios: $ipa"

if [ "$upload" = 1 ]; then
  echo "store-ios: upload to App Store Connect (TestFlight)"
  API_PRIVATE_KEYS_DIR="$tmp" xcrun altool --upload-app --type ios -f "$ipa" --apiKey "$key_id" --apiIssuer "$issuer"
fi
