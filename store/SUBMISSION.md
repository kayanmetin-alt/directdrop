# DirectDrop — App Store & Google Play yayın rehberi

> **Tek seferlik kurulum + otomatik yayın:** [store/ONCE_SETUP.md](ONCE_SETUP.md)  
> Secrets hazır olduktan sonra: `git tag v1.3.0 && git push origin v1.3.0` → GitHub Actions **Release Mobile** derler ve mağazalara yükler.

Sürüm: **1.3.0 (14)**

## Ön koşullar (sizin tarafınızda)

- [ ] Apple Developer Program ($99/yıl) — Team ID: `ZX94LAT88X`
- [ ] Google Play Developer hesabı ($25 tek seferlik)
- [ ] Gizlilik politikası yayında (GitHub Pages — aşağıya bakın)
- [ ] Android upload keystore oluşturuldu
- [ ] App Store Connect’te uygulama kaydı (`com.directdrop.app`)
- [ ] Play Console’da uygulama kaydı (`com.directdrop.app`)

---

## GitHub Pages (gizlilik politikası)

1. GitHub → repo **directdrop** → **Settings** → **Pages**
2. Source: **Deploy from a branch** → Branch: `main` → Folder: **`/docs`**
3. Birkaç dakika sonra: `https://kayanmetin-alt.github.io/directdrop/privacy-policy.html`

Bu URL’yi App Store Connect ve Play Console’a girin.

---

## Android — Play Store

### Upload keystore (bir kez)

```bash
keytool -genkey -v -keystore android/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
cp android/key.properties.example android/key.properties
```

### App Bundle

```bash
flutter build appbundle --release
```

Çıktı: `build/app/outputs/bundle/release/app-release.aab`

GitHub Actions: **Build Android App Bundle** (Secrets gerekli — aşağıda)

### Play Console

- Store metinleri: `store/play-store/metadata-tr.txt`
- Data safety + full-screen intent bildirimi
- Ekran görüntüleri + feature graphic 1024×500

---

## iOS — App Store

```bash
flutter build ipa --release --export-options-plist=ios/ExportOptions.plist
```

Metinler: `store/app-store/metadata-tr.txt`

---

## GitHub Secrets (Android CI imzalama)

| Secret | Açıklama |
|--------|----------|
| `ANDROID_KEYSTORE_BASE64` | `base64 -i upload-keystore.jks` |
| `ANDROID_KEY_ALIAS` | `upload` |
| `ANDROID_KEY_PASSWORD` | key şifresi |
| `ANDROID_STORE_PASSWORD` | keystore şifresi |

---

## Kod tarafı tamamlandı

- iOS debug ağ girdileri kaldırıldı, export compliance, APNs production
- Android release signing, adaptive icon, ProGuard hazır
- Gizlilik politikası + Hakkında ekranı
- PrivacyInfo.xcprivacy, ExportOptions.plist

## Sizin yapmanız gerekenler

- Özel uygulama ikonu (Flutter varsayılanını değiştirin)
- Mağaza ekran görüntüleri
- Keystore + GitHub Pages
