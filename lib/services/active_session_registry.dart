import 'dart:async';

import '../providers/transfer_session_controller.dart';

/// Aktif transfer oturumunu uygulama kapanırken temizlemek için.
class ActiveSessionRegistry {
  ActiveSessionRegistry._();

  static final ActiveSessionRegistry instance = ActiveSessionRegistry._();

  TransferSessionController? _controller;

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
    if (controller == null) return;
    await controller.disconnect();
    if (identical(_controller, controller)) {
      _controller = null;
    }
  }
}
