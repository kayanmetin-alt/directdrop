import 'package:flutter/foundation.dart';

import '../providers/transfer_session_controller.dart';

/// Aktif transfer oturumunu takip eder; uygulama kapanırken veya yeniden açılırken temizler.
class ActiveSessionRegistry {
  ActiveSessionRegistry._();

  static final ActiveSessionRegistry instance = ActiveSessionRegistry._();

  TransferSessionController? _controller;

  TransferSessionController? get activeController {
    final controller = _controller;
    if (controller == null || controller.isDisposed) return null;
    return controller;
  }

  bool get hasActiveSession => activeController != null;

  void register(TransferSessionController controller) {
    _controller = controller;
  }

  void unregister(TransferSessionController controller) {
    if (identical(_controller, controller)) {
      _controller = null;
    }
  }

  Future<void> disconnectActive() async {
    final controller = _controller;
    if (controller == null || controller.isDisposed) return;
    try {
      await controller.disconnect();
    } catch (e) {
      debugPrint('Aktif oturum kapatılamadı: $e');
    }
    if (identical(_controller, controller)) {
      _controller = null;
    }
  }

  /// Yeniden açılışta veya çökme sonrası kalan oturumu zorla bırak.
  Future<void> forceReleaseAll() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    try {
      if (!controller.isDisposed) {
        await controller.disconnect();
      }
    } catch (e) {
      debugPrint('forceReleaseAll disconnect: $e');
    }
    try {
      if (!controller.isDisposed) {
        controller.dispose();
      }
    } catch (e) {
      debugPrint('forceReleaseAll dispose: $e');
    }
  }
}
