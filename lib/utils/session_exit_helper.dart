import 'package:flutter/material.dart';

import '../main.dart';
import '../providers/transfer_session_controller.dart';
import '../services/active_session_registry.dart';
import '../services/paired_auto_connect_service.dart';
import '../services/recent_connection_service.dart';

/// Odadan çıkış — yeniden bağlanmayı durdurur ve ana sayfaya döner.
class SessionExitHelper {
  SessionExitHelper._();

  static bool _leaving = false;

  /// Firebase `peerDeparted` sinyali — aktif oturum varsa ana sayfaya dön.
  static Future<void> handlePeerDepartedSignal({
    required String fromDeviceId,
    required String fromDeviceName,
  }) async {
    if (RecentConnectionService.instance.isReconnectFlowActiveFor(fromDeviceId)) {
      return;
    }

    final controller = ActiveSessionRegistry.instance.activeController;
    if (controller == null) return;
    if (controller.userInitiatedLeave ||
        controller.peerHasLeft ||
        controller.supersededByReconnect) {
      return;
    }
    if (controller.peerDeviceId != fromDeviceId) return;

    // Kısa debounce — arka plan kopmasındaki yanlış sinyaller için.
    await Future<void>.delayed(const Duration(seconds: 2));

    // Debounce sırasında karşı cihaz yeniden bağlanmış olabilir: bu durumda
    // gelen sinyal ESKİ (öldürülen) oturuma ait bayat bir sinyaldir; yeni
    // oturumu kapatmamalıyız. Aynı peerDeviceId'yi paylaştıkları için bu
    // kontroller şarttır.
    if (RecentConnectionService.instance.isReconnectFlowActiveFor(fromDeviceId)) {
      return;
    }
    final current = ActiveSessionRegistry.instance.activeController;
    // Debounce sırasında yeni bir oturum (yeni controller) devraldıysa dokunma.
    if (!identical(current, controller)) return;
    if (controller.isDisposed ||
        controller.peerHasLeft ||
        controller.supersededByReconnect ||
        controller.userInitiatedLeave) {
      return;
    }
    // Bu arada yeniden bağlandıysa bayat sinyali yok say.
    if (controller.isConnected || controller.isReconnecting) return;

    await leaveAndGoHome(
      controller: controller,
      peerDeviceId: fromDeviceId,
      snackMessage: '$fromDeviceName bağlantıyı kapattı',
      userInitiatedDisconnect: false,
    );
  }

  static Future<void> leaveAndGoHome({
    required TransferSessionController controller,
    String? peerDeviceId,
    BuildContext? context,
    String? snackMessage,
    bool userInitiatedDisconnect = true,
  }) async {
    if (_leaving) return;
    _leaving = true;

    final resolvedPeerId = peerDeviceId ?? controller.peerDeviceId;

    PairedAutoConnectService.instance.setManualSessionActive(true);
    try {
      if (resolvedPeerId != null) {
        RecentConnectionService.instance.abandonPeerConnection(resolvedPeerId);
        await PairedAutoConnectService.instance.leavePeer(resolvedPeerId);
      } else {
        RecentConnectionService.instance.clearAutoConnectActive();
      }

      ActiveSessionRegistry.instance.unregister(controller);
      if (!controller.isDisposed) {
        await controller.disconnect(userInitiated: userInitiatedDisconnect);
        controller.dispose();
      }
    } finally {
      PairedAutoConnectService.instance.pauseAutoConnectFor(
        const Duration(minutes: 2),
      );
      PairedAutoConnectService.instance.setManualSessionActive(false);
      _leaving = false;
    }

    final nav = rootNavigatorKey.currentState;
    if (nav != null) {
      nav.popUntil((route) => route.isFirst);
    } else if (context != null && context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }

    if (snackMessage != null) {
      final messengerContext = rootNavigatorKey.currentContext;
      if (messengerContext != null && messengerContext.mounted) {
        ScaffoldMessenger.of(messengerContext).showSnackBar(
          SnackBar(content: Text(snackMessage)),
        );
      }
    }
  }
}
