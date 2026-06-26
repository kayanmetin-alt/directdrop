import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../firebase_options.dart';
import 'app_check_service.dart';
import 'firebase_auth_service.dart';

/// RTDB erişimi için merkezi yardımcı.
abstract final class FirebaseRtdbService {
  /// Bölgesel (ör. europe-west1) RTDB örneği.
  ///
  /// Apple (iOS/macOS) native Firebase SDK'sı, FlutterFire'ın Dart
  /// `FirebaseOptions`'ından gelen bölgesel `databaseURL`'i `FirebaseDatabase.instance`
  /// için güvenilir biçimde kullanmaz; varsayılan `us-central1`'e bağlanmaya çalışır
  /// ve sunucu bağlantıyı "Database lives in a different region" diyerek kapatır.
  /// Bu durumda tüm okumalar `permission-denied`, yazmalar `unknown` döner
  /// (.info/connected dahil). Bunu önlemek için URL'i açıkça veriyoruz.
  static FirebaseDatabase get database => FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: DefaultFirebaseOptions.currentPlatform.databaseURL,
      );

  /// Tek seferlik okuma için güvenli yardımcı.
  ///
  /// `DatabaseReference.get()` (ve `once()`), aynı VEYA üst yol üzerinde aktif
  /// bir `onValue`/`onChild*` dinleyicisi varken bazı `firebase_database`
  /// sürümlerinde — özellikle Windows/masaüstü — hiçbir zaman tamamlanmaz
  /// ("TimeoutException after 0:00:10 ... Future not completed").
  /// Bkz. flutterfire #13482. Yeniden bağlanma akışı `pairInvites/{myId}`,
  /// `reconnectRequests/{myId}` ve `pairConnect/{pairKey}` yollarını sürekli
  /// dinlediği için bu yollardaki `.get()` çağrıları Windows'ta 10 sn askıda
  /// kalıp isteği ~50-60 sn geciktiriyordu.
  ///
  /// Dinleyici tabanlı okuma bu hatadan etkilenmez: ilk olayı (mevcut değer)
  /// alıp aboneliği kapatır. Var olmayan yol için de `exists == false` snapshot
  /// ile hemen tamamlanır.
  static Future<DataSnapshot> readOnce(
    DatabaseReference ref, {
    Duration timeout = const Duration(seconds: 12),
  }) {
    return ref.onValue.map((event) => event.snapshot).first.timeout(timeout);
  }

  /// RTDB okuma/yazımından önce auth + App Check hazırlığını garanti eder.
  static Future<void> ensureReady() async {
    await FirebaseAuthService.instance.ensureSignedIn();
    await AppCheckService.ensureActivated();
    await FirebaseAuthService.instance.requireUid();
  }
}
