#!/bin/bash
# DirectDrop macOS uygulamasını derler ve /Applications'a kurar.
# Kullanım: chmod +x scripts/install_macos_app.sh && ./scripts/install_macos_app.sh

set -e

cd "$(dirname "$0")/.."

echo "==> Bağımlılıklar"
flutter pub get

echo "==> macOS CocoaPods"
cd macos && pod install && cd ..

echo "==> Release build"
flutter build macos --release

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
