#!/usr/bin/env bash
# GitHub Secrets için dosyaları base64'e çevirir (ekrana yazmaz).
set -euo pipefail

echo "DirectDrop — GitHub Secrets hazırlık"
echo "Repo → Settings → Secrets and variables → Actions"
echo ""

if [[ -f android/upload-keystore.jks ]]; then
  echo "ANDROID_KEYSTORE_BASE64:"
  base64 -i android/upload-keystore.jks | pbcopy 2>/dev/null || base64 -i android/upload-keystore.jks
  echo "(Mac'te panoya kopyalandı)"
else
  echo "⚠ android/upload-keystore.jks bulunamadı — önce keytool ile oluşturun."
fi

echo ""
echo "Manuel secret'lar:"
echo "  ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD, ANDROID_STORE_PASSWORD"
echo "  PLAY_STORE_JSON (service account JSON tam metin)"
echo "  APPSTORE_KEY_ID, APPSTORE_ISSUER_ID, APPSTORE_PRIVATE_KEY"
echo "  IOS_DIST_CERT_P12_BASE64, IOS_DIST_CERT_PASSWORD, IOS_PROVISION_PROFILE_BASE64"
echo ""
echo "Detay: store/ONCE_SETUP.md"
