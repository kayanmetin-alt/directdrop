#!/bin/bash
# DirectDrop macOS — Developer ID ile imzalı, notarize edilmiş .dmg üretir.
# (Mac App Store DIŞI dağıtım: web sitesinden indirme içindir.)
#
# Gereksinimler (bir kez kurulur):
#   1) "Developer ID Application: <Ad> (TEAMID)" sertifikası Keychain'de olmalı.
#      Xcode > Settings > Accounts > (takım) > Manage Certificates > +
#        > "Developer ID Application"   ya da developer.apple.com.
#   2) Notarization kimlik bilgisi bir Keychain profiline kaydedilmeli:
#      xcrun notarytool store-credentials "directdrop-notary" \
#        --apple-id "<apple-id-email>" \
#        --team-id "ZX94LAT88X" \
#        --password "<app-specific-password>"
#      (app-specific password: appleid.apple.com > Oturum Açma ve Güvenlik)
#
# Kullanım:
#   chmod +x scripts/build_macos_dmg.sh
#   ./scripts/build_macos_dmg.sh
#
# Ortam değişkenleri (opsiyonel):
#   DEVID_IDENTITY  : İmza kimliği (vars: ilk "Developer ID Application" sertifikası)
#   NOTARY_PROFILE  : notarytool keychain profili (vars: directdrop-notary)
#   SKIP_NOTARIZE=1 : Yalnızca imzala + dmg üret, notarize etme (test için)

set -euo pipefail

cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-directdrop-notary}"
ENTITLEMENTS="macos/Runner/Release.entitlements"

# --- Sürüm ---
VERSION="$(grep '^version:' pubspec.yaml | sed 's/^version:[[:space:]]*//' | cut -d'+' -f1 | tr -d '[:space:]')"
echo "==> Sürüm: $VERSION"

# --- İmza kimliği ---
if [[ -z "${DEVID_IDENTITY:-}" ]]; then
  DEVID_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ {print $2; exit}')"
fi
if [[ -z "${DEVID_IDENTITY:-}" ]]; then
  echo "HATA: 'Developer ID Application' sertifikası bulunamadı."
  echo "      Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"
  exit 1
fi
echo "==> İmza kimliği: $DEVID_IDENTITY"

# --- Derleme (imzasız) ---
# Doğrudan dağıtımda provisioning profile gerekmez. Projeyi imzasız derleyip
# (CODE_SIGNING_ALLOWED=NO) ardından Developer ID ile elle imzalıyoruz; böylece
# hem yerelde hem CI'da (development profile olmadan) tutarlı çalışır.
echo "==> Derleme (imzasız) — sonrasında Developer ID ile imzalanacak"
flutter pub get
flutter build macos --release --config-only
( cd macos && pod install )
rm -rf build/macos
xcodebuild \
  -workspace macos/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -derivedDataPath build/macos \
  CODE_SIGNING_ALLOWED=NO \
  build | tail -n 8

APP="build/macos/Build/Products/Release/DirectDrop.app"
[[ -d "$APP" ]] || { echo "HATA: $APP yok"; exit 1; }

# --- İçeriden dışarıya imzala (hardened runtime) ---
echo "==> Gömülü framework / dylib imzalanıyor"
find "$APP/Contents/Frameworks" \( -name "*.framework" -o -name "*.dylib" \) -print0 2>/dev/null |
  while IFS= read -r -d '' item; do
    codesign --force --timestamp --options runtime \
      --sign "$DEVID_IDENTITY" "$item"
  done

echo "==> Uygulama imzalanıyor"
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$DEVID_IDENTITY" "$APP"

echo "==> İmza doğrulanıyor"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- DMG üret ---
DIST="dist/macos"
mkdir -p "$DIST"
DMG="$DIST/DirectDrop-$VERSION.dmg"
DMG_STABLE="$DIST/DirectDrop.dmg"
rm -f "$DMG" "$DMG_STABLE"

echo "==> DMG hazırlanıyor"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DirectDrop" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "    $DMG"

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "==> SKIP_NOTARIZE=1 — notarize atlandı."
  cp "$DMG" "$DMG_STABLE"
  echo "Tamamlandı (notarize edilmedi): $DMG"
  exit 0
fi

# --- Notarize + staple ---
echo "==> Notarize ediliyor (Apple'a gönderiliyor, birkaç dakika sürebilir)"
if [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" && -n "${NOTARY_KEY_FILE:-}" ]]; then
  # CI: App Store Connect API anahtarı (.p8) ile
  xcrun notarytool submit "$DMG" \
    --key "$NOTARY_KEY_FILE" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait
else
  # Yerel: Keychain profili ile
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
fi

echo "==> Staple (notarization bileti dmg'ye işleniyor)"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

cp "$DMG" "$DMG_STABLE"
echo ""
echo "Tamamlandı:"
echo "  Sürümlü : $DMG"
echo "  Sabit ad: $DMG_STABLE  (web sitesi 'latest' linki için)"
