#!/bin/bash
# pubspec.yaml sürümünü iOS/macOS Xcode yapılandırmasına yazar.
# iPhone + Mac güncelleyecekseniz çalıştırın. "Running pod install" 5–15 dk sürebilir.

set -e
cd "$(dirname "$0")/.."

echo "==> pubspec sürümü → native yapılandırma"
echo "    (pod install aşamasında takılmış gibi görünebilir — normal, bekleyin)"
flutter pub get
echo "==> iOS yapılandırması..."
flutter build ios --config-only
echo "==> macOS yapılandırması..."
flutter build macos --config-only

if [[ -f ios/Flutter/Generated.xcconfig ]]; then
  echo "iOS: $(grep -E '^FLUTTER_BUILD_NAME=|^FLUTTER_BUILD_NUMBER=' ios/Flutter/Generated.xcconfig | tr '\n' ' ')"
fi
if [[ -f macos/Flutter/ephemeral/Flutter-Generated.xcconfig ]]; then
  echo "macOS: $(grep -E '^FLUTTER_BUILD_NAME=|^FLUTTER_BUILD_NUMBER=' macos/Flutter/ephemeral/Flutter-Generated.xcconfig | tr '\n' ' ')"
fi
