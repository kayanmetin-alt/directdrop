#!/bin/bash
# DirectDrop macOS uygulamasını derler ve /Applications'a kurar.
# Kullanım: chmod +x scripts/install_macos_app.sh && ./scripts/install_macos_app.sh

set -e

cd "$(dirname "$0")/.."

echo "==> macOS uygulama ikonları (kaynak: assets/branding/directdrop-app-icon-source.png)"
ICON_SRC="assets/branding/directdrop-app-icon-source.png"
ICON_DEST="macos/Runner/Assets.xcassets/AppIcon.appiconset"
if [[ ! -f "$ICON_SRC" ]]; then
  echo "Hata: $ICON_SRC bulunamadı."
  exit 1
fi
for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" "$ICON_SRC" --out "$ICON_DEST/app_icon_${size}.png" >/dev/null
done

echo "==> Bağımlılıklar (Mac sürümü)"
flutter pub get
flutter build macos --config-only

echo "==> macOS CocoaPods (ilk seferde 5–15 dk sürebilir, bekleyin)"
cd macos && pod install --verbose && cd ..

echo "==> Release build"
if ! flutter build macos --release; then
  echo "==> flutter build başarısız; xcodebuild ile deneniyor..."
  cd macos
  xcodebuild \
    -workspace Runner.xcworkspace \
    -scheme Runner \
    -configuration Release \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM=ZX94LAT88X \
    CODE_SIGN_IDENTITY="Apple Development" \
    | tail -20
  cd ..
fi

APP_SRC="build/macos/Build/Products/Release/DirectDrop.app"
APP_DEST="/Applications/DirectDrop.app"

if [[ ! -d "$APP_SRC" ]]; then
  echo "Hata: $APP_SRC bulunamadı."
  exit 1
fi

echo "==> Applications'a kuruluyor"
if [[ -d "$APP_DEST" ]]; then
  rm -rf "$APP_DEST"
fi
cp -R "$APP_SRC" "$APP_DEST"

echo ""
echo "Tamamlandı: $APP_DEST"
echo "Launchpad veya Spotlight'tan DirectDrop'u açın (flutter run değil)."
echo ""
echo "Not: Dock'taki eski kısayol varsa çıkarıp yeniden ekleyin."
