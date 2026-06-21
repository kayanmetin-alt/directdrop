# DirectDrop — Fastlane kurulumu

Fastlane, release derlemelerini mağazalara otomatik yüklemek için kullanılır. CI (GitHub Actions) ve yerel Mac'te aynı lane'ler çalışır.

## 1. Ön koşullar

```bash
# Ruby bağımlılıkları (proje kökünden)
cd /path/to/directdrop
bundle install

# veya sistem geneli
brew install fastlane
```

Flutter SDK kurulu olmalı (`flutter doctor`).

## 2. Yerel ortam dosyası

```bash
cd fastlane
cp .env.example .env
# .env içindeki değerleri doldurun
```

`.env` dosyası `.gitignore`'dadır; asla commit etmeyin.

## 3. Android

### 3a. Upload keystore (bir kez)

```bash
cd android
keytool -genkey -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
cp key.properties.example key.properties
# key.properties içindeki şifreleri girin
```

### 3b. Play Console API JSON

1. [Google Cloud Console](https://console.cloud.google.com) → Google Play Android Developer API etkin
2. Play Console → Setup → API access → service account → JSON indir
3. `.env` içinde:
   ```
   PLAY_STORE_JSON_PATH=/Users/.../play-store.json
   PLAY_STORE_TRACK=internal
   ```

### 3c. Komutlar

```bash
cd fastlane
bundle exec fastlane android build    # AAB derle
bundle exec fastlane android deploy   # Play Store'a yükle
```

## 4. iOS

### Seçenek A — fastlane match (önerilen)

1. GitHub'da **private** repo oluşturun (ör. `directdrop-certificates`)
2. `Matchfile` içindeki `git_url` satırını güncelleyin
3. `.env` içine `APPLE_ID` ve `MATCH_PASSWORD` ekleyin
4. İlk kurulum:

```bash
cd fastlane
bundle exec fastlane match appstore
```

Sertifikalar match reposuna yüklenir. CI için aynı `MATCH_PASSWORD` GitHub Secret olarak eklenir.

### Seçenek B — Manuel sertifika (CI'daki mevcut yöntem)

Xcode → Distribution sertifikası + App Store provisioning profile export edin.  
GitHub Secrets: `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_PASSWORD`, `IOS_PROVISION_PROFILE_BASE64`  
Detay: `store/ONCE_SETUP.md`

### 4b. App Store Connect API Key

App Store Connect → Users and Access → Integrations → App Store Connect API → Key oluştur  
`.p8` dosyasını indirin; `.env` içine `APPSTORE_KEY_ID`, `APPSTORE_ISSUER_ID`, `APPSTORE_PRIVATE_KEY` yazın.

### 4c. Komutlar

```bash
cd fastlane
bundle exec fastlane ios build     # IPA derle
bundle exec fastlane ios deploy    # App Store Connect / TestFlight'a yükle
```

## 5. GitHub CI ile otomatik yayın

Secrets hazır olduktan sonra:

```bash
git tag v1.3.1
git push origin v1.3.1
```

Workflow: `.github/workflows/release-mobile.yml`  
Lane'ler: `fastlane android deploy`, `fastlane ios deploy`

## 6. Lane özeti

| Lane | Açıklama |
|------|----------|
| `android build` | `flutter build appbundle --release` |
| `android deploy` | AAB → Play Store (track: internal varsayılan) |
| `ios build` | `flutter build ipa --release` |
| `ios deploy` | IPA → App Store Connect |
| `match appstore` | iOS dağıtım sertifikası + profile (match) |

## 7. Sorun giderme

| Hata | Çözüm |
|------|--------|
| `PLAY_STORE_JSON_PATH tanımlı değil` | `.env` oluşturun veya export edin |
| `AAB bulunamadı` | Önce `fastlane android build` |
| `IPA bulunamadı` | Önce `fastlane ios build` |
| match: repo erişim hatası | SSH key veya `MATCH_GIT_BASIC_AUTHORIZATION` |
| Play 403 | Service account'a Release manager yetkisi |

Genel mağaza checklist: `store/ONCE_SETUP.md`
