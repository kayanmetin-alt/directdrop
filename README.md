# DirectDrop

iPhone, Mac ve Windows arasında internet üzerinden anlık dosya transferi.

- **Firebase Realtime Database** → yalnızca oda eşleştirme ve WebRTC signaling
- **WebRTC Data Channel** → dosya verisi doğrudan cihazdan cihaza
- **Flutter** → iOS, macOS, Windows tek kod tabanı

## Özellikler

- 6 haneli oda kodu veya QR ile eşleştirme
- Çoklu dosya gönderimi
- 64 KB parçalar halinde güvenilir transfer (ACK + SHA-256 doğrulama)
- Büyük dosya desteği (GB seviyesine kadar)

## Kurulum (adım adım)

Terminalde **yorum satırlarını (`#` ile başlayanları) kopyalamayın** — sadece komutları çalıştırın.

### 1. Proje klasörüne girin

```bash
cd ~/directdrop
```

### 2. Flutter bağımlılıkları

```bash
flutter pub get
```

### 3. iOS / macOS native bağımlılıkları

```bash
cd ios && pod install && cd ..
cd macos && pod install && cd ..
```

Veya tek seferde:

```bash
chmod +x setup.sh && ./setup.sh
```

### 4. Firebase yapılandırması

`flutterfire` komutu PATH'te olmayabilir. Önce şunu ekleyin:

```bash
export PATH="$PATH:$HOME/.pub-cache/bin"
```

Kalıcı yapmak için `~/.zshrc` dosyanıza da aynı satırı ekleyin.

Sonra Firebase CLI ile giriş yapın ve projeyi bağlayın:

```bash
dart pub global activate flutterfire_cli
flutterfire configure
```

Firebase Console'da önce:
- Realtime Database oluşturun
- iOS, macOS, Windows uygulaması ekleyin (`com.directdrop.app`)

### 5. Database kurallarını deploy edin

**Proje kök dizininden** çalıştırın (`ios/` içinden değil):

```bash
cd ~/directdrop
firebase login
firebase use --add
firebase deploy --only database
```

### 6. Uygulamayı çalıştırın

```bash
flutter run -d macos
```

iOS için:

```bash
flutter run -d ios
```

Windows için:

```bash
flutter run -d windows
```

### Windows kurulum paketi (Setup.exe)

Mac’te Windows `.exe` derlenemez; kurulum dosyasını **Windows bilgisayarda** veya **GitHub Actions** ile oluşturun.

**Windows bilgisayarda (önerilen):**

1. [Flutter Windows kurulumu](https://docs.flutter.dev/get-started/install/windows) + Visual Studio 2022 (Desktop development with C++)
2. [Inno Setup 6](https://jrsoftware.org/isdl.php) kurun
3. Proje klasöründe PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1
```

Çıktı: `dist\windows\DirectDrop-Setup-1.0.0.exe`

Bu dosyayı hedef PC’ye kopyalayıp çift tıklayın — macOS’taki gibi kurulum sihirbazı açılır, Başlat menüsü ve isteğe bağlı masaüstü kısayolu oluşturulur.

**GitHub Actions ile (Windows PC yoksa):**

1. Projeyi GitHub’a push edin
2. Actions → **Build Windows Installer** → **Run workflow**
3. Tamamlanınca **DirectDrop-Windows-Setup** artifact’ından `.exe` indirin

Kurulum sonrası uygulama `%LOCALAPPDATA%\Programs\DirectDrop\` altına yüklenir. İndirilen dosyalar: `%USERPROFILE%\Documents\DirectDrop\Downloads\`

> **Not:** Bazı PC’lerde [Visual C++ Redistributable (x64)](https://aka.ms/vs/17/release/vc_redist.x64.exe) gerekebilir; kurulum sihirbazı bunu hatırlatır.

## Sık karşılaşılan hatalar

| Hata | Çözüm |
|------|-------|
| `command not found: flutterfire` | `export PATH="$PATH:$HOME/.pub-cache/bin"` |
| `mobile_scanner ... higher minimum deployment target` | iOS 15.5 gerekir (Podfile'da düzeltildi), `cd ios && pod install` |
| `cd: no such file or directory: macos` | Önce `cd ~/directdrop` yapın, `ios/` içindeyken `macos` yoktur |
| `Target file "#" not found` | Komuttaki `# veya ios / windows` yorumunu kopyalamayın |
| `could not locate firebase.json` | `cd ~/directdrop` sonra `firebase deploy` |

## Kullanım

1. **Gönderen cihaz:** "Transfer Başlat" → oda kodu / QR oluşur
2. **Alan cihaz:** "Koda Katıl" → kodu gir veya QR okut
3. Bağlantı kurulunca "Dosya Gönder" ile transfer başlat

Alınan dosyalar:

- **iOS/macOS:** `Documents/DirectDrop/Downloads/`
- **Windows:** `%USERPROFILE%\Documents\DirectDrop\Downloads\`

## Mimari

```
┌─────────┐     signaling (Firebase)     ┌─────────┐
│ Cihaz A │ ◄──────────────────────────► │ Cihaz B │
└────┬────┘                              └────┬────┘
     │         WebRTC Data Channel (P2P)       │
     └──────────────────────────────────────►│
```

## App Store & Google Play hazırlığı

Detaylı rehber: **[store/SUBMISSION.md](store/SUBMISSION.md)**

| Gereksinim | Durum |
|------------|--------|
| Bundle ID `com.directdrop.app` | ✅ |
| iOS APNs + push | ✅ |
| Gizlilik politikası (`docs/privacy-policy.html`) | ✅ — GitHub Pages açın |
| Uygulama içi link (Ana sayfa → Hakkında) | ✅ |
| Android release signing | ⚠️ `android/key.properties` siz oluşturacaksınız |
| Mağaza metinleri | ✅ `store/` |
| Ekran görüntüleri / özel ikon | ❌ Sizin hazırlamanız gerekir |

Gizlilik URL (Pages açınca): `https://kayanmetin-alt.github.io/directdrop/privacy-policy.html`

```bash
flutter build appbundle --release   # Play Store
flutter build ipa --release --export-options-plist=ios/ExportOptions.plist  # App Store
```

## Güvenlik (Firebase Auth)

Uygulama açılışında **anonim Firebase Auth** oturumu açılır. Realtime Database kuralları buna göre kilitlenmiştir:

| Veri | Kim okuyabilir? | Kim yazabilir? |
|------|-----------------|----------------|
| `devices/{id}` (online, isim…) | Giriş yapmış her cihaz | Yalnızca `ownerUid` sahibi |
| `devices/{id}/wakeRequests` | Hedef cihaz sahibi | Gönderen (`fromAuthUid`) veya hedef (silme) |
| `pairInvites/{targetId}/{fromId}` | Giriş yapmış kullanıcılar | Davet gönderen (`fromAuthUid`) |
| `rooms/{kod}` | Giriş yapmış cihazlar | Oda katılımcıları (`allowedUids`) |

**Kurulum (bir kez):**

1. [Firebase Console](https://console.firebase.google.com) → projeniz → **Authentication** → **Sign-in method** → **Anonymous** → **Enable**
2. Proje kökünde kuralları yayınlayın:

```bash
cd ~/directdrop
firebase deploy --only database
```

3. Tüm cihazlarda uygulamayı güncelleyin (Mac: `./scripts/install_macos_app.sh`, Windows: yeni installer)

> **Önemli:** Kuralları deploy etmeden veya Anonymous Auth açmadan yeni sürüm çalışmaz. Eski açık kurallar varken de eski build’ler çalışmaya devam eder.

## Production notları

MVP şu an Google STUN sunucularını kullanır. Canlı ortamda:

1. **TURN sunucusu** ekleyin (coturn) — kurumsal ağlarda P2P başarısız olursa gerekli
2. Eski odalar için **Cloud Function** ile otomatik temizlik ekleyin
3. İsteğe bağlı: Firebase **App Check** ile anonim oturum kötüye kullanımını azaltın

`lib/services/webrtc_service.dart` içindeki `_iceServers` listesine TURN bilgilerinizi ekleyin:

```dart
{
  'urls': 'turn:turn.example.com:3478',
  'username': 'user',
  'credential': 'pass',
}
```

## Proje yapısı

```
lib/
├── main.dart
├── firebase_options.dart
├── models/
├── services/
│   ├── firebase_auth_service.dart
│   ├── firebase_signaling_service.dart
│   ├── webrtc_service.dart
│   └── file_transfer_service.dart
├── providers/
│   └── transfer_session_controller.dart
├── screens/
└── widgets/
```

## Lisans

MIT
