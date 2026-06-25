import 'dart:io';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// Firebase App Check'i etkinleştirir. App Check, isteklerin gerçekten bu
/// uygulamadan geldiğini doğrulayan bir jeton ekler; böylece uygulama dışı
/// scriptlerin anonim auth ile RTDB'yi kötüye kullanması (cihaz enumerasyonu,
/// wake/reconnect spam'i, oda kodu brute-force) zorlaşır.
///
/// NOT: Bu yalnızca jeton ÜRETİR. Gerçek zorunluluk Firebase Console'dan
/// (App Check → Enforce) açılana kadar mevcut istekler bozulmaz. Önce
/// uygulamayı kaydedip debug jetonlarını ekleyin, ardından enforcement'ı açın.
///
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
