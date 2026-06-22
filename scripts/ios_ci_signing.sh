#!/usr/bin/env bash
# CI: App Store dağıtım imzasını yapılandırır (Release.xcconfig → Manual).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_XCCONFIG="$ROOT/ios/Flutter/Release.xcconfig"
EXPORT_OPTIONS="$ROOT/ios/ExportOptions.plist"

if [[ -z "${IOS_DIST_CERT_P12_BASE64:-}" ]]; then
  echo "IOS_DIST_CERT_P12_BASE64 yok — yerel Automatic imza kullanılacak."
  exit 0
fi

CERT_PATH="${RUNNER_TEMP:-/tmp}/dist.p12"
PP_PATH="${RUNNER_TEMP:-/tmp}/directdrop.mobileprovision"
PROFILE_PLIST="${RUNNER_TEMP:-/tmp}/profile.plist"
KEYCHAIN="${RUNNER_TEMP:-/tmp}/app-signing.keychain-db"
KEYCHAIN_PASSWORD="${IOS_DIST_CERT_PASSWORD:?IOS_DIST_CERT_PASSWORD gerekli}"

echo "$IOS_DIST_CERT_P12_BASE64" | base64 -d > "$CERT_PATH"
echo "$IOS_PROVISION_PROFILE_BASE64" | base64 -d > "$PP_PATH"
security cms -D -i "$PP_PATH" > "$PROFILE_PLIST"

PROFILE_UUID=$(/usr/libexec/PlistBuddy -c 'Print UUID' "$PROFILE_PLIST")
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c 'Print Name' "$PROFILE_PLIST")

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERT_PATH" -P "$KEYCHAIN_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychain -d user -s "$KEYCHAIN" login.keychain-db

mkdir -p ~/Library/MobileDevice/Provisioning\ Profiles
cp "$PP_PATH" ~/Library/MobileDevice/Provisioning\ Profiles/"$PROFILE_UUID".mobileprovision

cat > "$RELEASE_XCCONFIG" <<EOF
#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig"
#include "Generated.xcconfig"

DEVELOPMENT_TEAM=ZX94LAT88X
CODE_SIGN_STYLE=Manual
CODE_SIGN_IDENTITY=Apple Distribution
CODE_SIGN_IDENTITY[sdk=iphoneos*]=Apple Distribution
PROVISIONING_PROFILE_SPECIFIER=${PROFILE_NAME}
EOF

/usr/libexec/PlistBuddy -c "Set :provisioningProfiles:com.directdrop.app ${PROFILE_NAME}" "$EXPORT_OPTIONS" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:com.directdrop.app string ${PROFILE_NAME}" "$EXPORT_OPTIONS"

echo "App Store imzası hazır: ${PROFILE_NAME} (${PROFILE_UUID})"
security find-identity -v -p codesigning "$KEYCHAIN" || true
