import 'app_check_service.dart';
import 'firebase_auth_service.dart';

/// RTDB okuma/yazımından önce auth + App Check hazırlığını garanti eder.
abstract final class FirebaseRtdbService {
  static Future<void> ensureReady() async {
    await FirebaseAuthService.instance.ensureSignedIn();
    await AppCheckService.ensureActivated();
    await FirebaseAuthService.instance.requireUid();
  }
}
