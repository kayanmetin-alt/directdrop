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

  /// RTDB okuma/yazımından önce auth + App Check hazırlığını garanti eder.
  static Future<void> ensureReady() async {
    await FirebaseAuthService.instance.ensureSignedIn();
    await AppCheckService.ensureActivated();
    await FirebaseAuthService.instance.requireUid();
  }
}
