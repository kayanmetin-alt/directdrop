import 'package:flutter/foundation.dart';

import 'active_session_registry.dart';

/// Uygulama açılışında ve çökme sonrası yarım kalan oturumları temizler.
class SessionCleanupService {
  SessionCleanupService._();

  static final SessionCleanupService instance = SessionCleanupService._();

  Future<void> resetOnLaunch() async {
    try {
      await ActiveSessionRegistry.instance.forceReleaseAll();
    } catch (e, stack) {
      debugPrint('Oturum sıfırlama (launch): $e\n$stack');
    }
  }
}
