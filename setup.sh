#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "==> Flutter bağımlılıkları"
flutter pub get

echo "==> iOS CocoaPods"
cd ios && pod install && cd ..

echo "==> macOS CocoaPods"
cd macos && pod install && cd ..

echo ""
echo "Kurulum tamam. Sıradaki adımlar:"
echo "  1. Firebase Console'da proje oluşturun"
echo "  2. Şu komutu çalıştırın:"
echo "     export PATH=\"\$PATH:\$HOME/.pub-cache/bin\""
echo "     flutterfire configure"
echo "  3. Uygulamayı başlatın:"
echo "     flutter run -d macos"
