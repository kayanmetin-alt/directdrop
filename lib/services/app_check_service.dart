import 'dart:io';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// Firebase App Check'i etkinleştirir. App Check, isteklerin gerçekten bu
/// uygulamadan geldiğini doğrulayan bir jeton ekler; böylece uygulama dışı
/// scriptlerin anonim auth ile RTDB'yi kötüye kullanması zorlaşır.
///
/// **Console'da zorunlu kılma (Enforce):**
/// 1. Firebase Console → App Check → uygulamayı kaydet (iOS/Android/macOS).
/// 2. Debug build için: Xcode/Android log'undan debug token'ı kopyala →
///    App Check → Manage debug tokens → ekle.
/// 3. Realtime Database → App Check sekmesi → **Enforce** aç.
/// 4. Windows/Linux App Check desteklemez; bu platformlar RTDB'ye erişmeye
///    devam eder (mobil/macOS istemcileri korunur).
///
/// NOT: Enforce açılmadan jeton üretilir ama reddedilmez.
/// Windows/Linux'ta App Check eklentisi yoktur; bu platformlarda atlanır.
class AppCheckService {
  AppCheckService._();

  static bool get _isSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  static Future<void> activate() async {
    if (!_isSupported) return;
    try {
      await FirebaseAppCheck.instance.activate(
        // Debug derlemelerinde debug provider kullan (Console'a debug jetonu
        // eklenmelidir). Release'de platform attestation sağlayıcıları.
        providerAndroid: kDebugMode
            ? const AndroidDebugProvider()
            : const AndroidPlayIntegrityProvider(),
        providerApple: kDebugMode
            ? const AppleDebugProvider()
            : const AppleDeviceCheckProvider(),
      );
    } catch (e) {
      debugPrint('App Check etkinleştirilemedi: $e');
    }
  }
}
