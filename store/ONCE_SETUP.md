# Tek seferlik kurulum (~30–45 dk)
# Sonrasında yayın: git tag v1.3.1 && git push origin v1.3.1
# veya GitHub → Actions → Release Mobile → Run workflow

## Ben (AI) ne yapabilir, ne yapamam?

| İş | Kim yapar? |
|----|------------|
| Kod, CI, Fastlane, imzalama scriptleri | ✅ Otomatik (repo'da) |
| Apple/Google **hesabı açma**, ödeme, kimlik doğrulama | ❌ Siz (yasal olarak başkası yapamaz) |
| İlk kez mağazada uygulama kaydı oluşturma | ❌ Siz (bir kez, ~15 dk) |
| Ekran görüntüsü, ikon tasarımı | ❌ Siz (bir kez) |
| GitHub Secrets'e anahtarları yapıştırma | ❌ Siz (bir kez, ~10 dk) |
| Sonraki her sürüm yükleme | ✅ **Otomatik** (tag push) |

---

## Adım 1 — GitHub Pages (gizlilik politikası)

GitHub → **directdrop** → Settings → Pages → Branch: `main`, Folder: **`/docs`**

URL: `https://kayanmetin-alt.github.io/directdrop/privacy-policy.html`

---

## Adım 2 — Google Play (Android)

### 2a. Play Console'da uygulama oluşturun (bir kez)

- Package: `com.directdrop.app`
- Gizlilik politikası URL'sini girin
- Store listing metinleri: `store/play-store/metadata-tr.txt`

### 2b. Upload keystore (bir kez, bilgisayarınızda)

```bash
cd android
keytool -genkey -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

**Bu dosyayı ve şifreleri güvenli yerde saklayın — kaybederseniz güncelleme yapamazsınız.**

### 2c. Play Console API erişimi (otomatik yükleme için)

1. [Google Cloud Console](https://console.cloud.google.com) → proje seçin
2. APIs → **Google Play Android Developer API** → Enable
3. Play Console → Setup → **API access** → Link cloud project
4. **Create service account** → JSON anahtar indir
5. Play Console → Users → service account e-postası → **Admin** veya en az Release manager

### 2d. GitHub Secrets (repo → Settings → Secrets → Actions)

| Secret | Değer |
|--------|--------|
| `ANDROID_KEYSTORE_BASE64` | `base64 -i android/upload-keystore.jks \| pbcopy` (Mac) |
| `ANDROID_KEY_ALIAS` | `upload` |
| `ANDROID_KEY_PASSWORD` | keystore key şifresi |
| `ANDROID_STORE_PASSWORD` | keystore şifresi |
| `PLAY_STORE_JSON` | Service account JSON dosyasının **tüm içeriği** |

---

## Adım 3 — Apple App Store (iOS)

### 3a. App Store Connect (bir kez)

1. [App Store Connect](https://appstoreconnect.apple.com) → Apps → **+** → New App
2. Bundle ID: `com.directdrop.app`
3. Gizlilik URL, kategori, yaş: `store/app-store/metadata-tr.txt`

### 3b. App Store Connect API Key (otomatik yükleme için)

1. App Store Connect → Users and Access → **Integrations** → **App Store Connect API**
2. **+** → Admin veya App Manager → Generate
3. `.p8` indir (AuthKey_XXXXX.p8) — **APNs anahtarından farklı**
4. Issuer ID ve Key ID not alın

### 3c. iOS imzalama sertifikası (CI için)

**Seçenek A — Önerilen: fastlane match (Mac'te bir kez)**

```bash
brew install fastlane
cd ios
fastlane match appstore --readonly false
```

Match git reposuna sertifikaları yükler; CI'da `MATCH_PASSWORD` secret yeterli.

**Seçenek B — Manuel export (daha basit, bir kez)**

Xcode → Settings → Accounts → Manage Certificates → Apple Distribution  
Ardından provisioning profile oluşturun (`com.directdrop.app` App Store).

CI için GitHub Secrets:

| Secret | Değer |
|--------|--------|
| `APPSTORE_ISSUER_ID` | App Store Connect Issuer ID |
| `APPSTORE_KEY_ID` | API Key ID |
| `APPSTORE_PRIVATE_KEY` | `.p8` dosyasının tam metni |
| `IOS_DIST_CERT_P12_BASE64` | Distribution cert .p12 (base64) |
| `IOS_DIST_CERT_PASSWORD` | .p12 şifresi |
| `IOS_PROVISION_PROFILE_BASE64` | App Store profile (base64) |

`.p12` export: Keychain Access → certificate → Export

---

## Adım 4 — İlk yükleme

Secrets hazır olduktan sonra:

```bash
git tag v1.3.0
git push origin v1.3.0
```

GitHub Actions **Release Mobile** workflow derler ve mağazalara yükler.

**İlk sürüm** bazen mağaza panelinden “Review” / “Publish” onayı ister — bu tek tıklama sizde kalır.

---

## Sonraki her güncelleme (2 dakika)

1. `pubspec.yaml` sürümünü artırın (ör. `1.3.1+15`)
2. Commit + push
3. `git tag v1.3.1 && git push origin v1.3.1`

Hepsi bu. CI gerisini yapar.

---

## Sorun giderme

- **Android: "Upload certificate mismatch"** → Play'e ilk yüklemeyi aynı keystore ile yapın
- **iOS: signing failed** → Profile/sertifika süresi dolmuş; yenileyin
- **Play: API 403** → Service account'a Release manager yetkisi verin
