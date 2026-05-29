#!/bin/bash
# DirectDrop Android APK derler.
set -e
cd "$(dirname "$0")/.."
flutter pub get
flutter build apk --release
echo ""
echo "APK: build/app/outputs/flutter-apk/app-release.apk"
