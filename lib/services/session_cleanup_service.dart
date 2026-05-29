import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'active_session_registry.dart';
import 'device_identity_service.dart';
import 'device_registry_service.dart';
import 'firebase_auth_service.dart';
import 'pair_connect_coordinator.dart';
import 'paired_devices_service.dart';
import 'recent_connection_service.dart';

/// Uygulama açılışında ve çökme sonrası yarım kalan oturumları temizler.
class SessionCleanupService {
  SessionCleanupService._();

  static final SessionCleanupService instance = SessionCleanupService._();

  static const _gracefulShutdownKey = 'directdrop_graceful_shutdown_v1';

  final DeviceRegistryService _registry = DeviceRegistryService();
  final PairConnectCoordinator _coordinator = PairConnectCoordinator();

  /// Önceki açılış düzgün kapanmadıysa (çökme / zorla kapatma) true.
  bool get lastLaunchWasUnclean => _lastLaunchWasUnclean;
  bool _lastLaunchWasUnclean = false;

  Future<void> resetOnLaunch() async {
    try {
      await ActiveSessionRegistry.instance.forceReleaseAll();
    } catch (e, stack) {
      debugPrint('Oturum sıfırlama (launch): $e\n$stack');
    }
  }

  /// main() içinde Auth sonrası, davet dinleyicisi öncesinde çağrılır.
  Future<void> onLaunchAfterAuth() async {
    final prefs = await SharedPreferences.getInstance();
    final graceful = prefs.getBool(_gracefulShutdownKey) ?? true;
    _lastLaunchWasUnclean = !graceful;

    if (_lastLaunchWasUnclean) {
      debugPrint(
        'Önceki oturum düzgün kapanmadı — yeniden bağlanma davetleri sıfırlanıyor.',
      );
      await _clearReconnectArtifacts();
      RecentConnectionService.instance.clearIncomingInvite();
      RecentConnectionService.instance.suppressAutoConnectThisLaunch = true;
    }

    await prefs.setBool(_gracefulShutdownKey, false);
  }

  Future<void> markGracefulShutdown() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_gracefulShutdownKey, true);
    } catch (e) {
      debugPrint('Graceful shutdown işareti yazılamadı: $e');
    }
  }

  Future<void> _clearReconnectArtifacts() async {
    try {
      await FirebaseAuthService.instance.ensureSignedIn();
      final myId = await DeviceIdentityService.instance.getDeviceId();
      await PairedDevicesService.instance.load();

      await _registry.clearAllInvitesForDevice(myId);

      for (final peer in PairedDevicesService.instance.devices) {
        await _coordinator.clearSession(
          myDeviceId: myId,
          peerDeviceId: peer.deviceId,
        );
        await _registry.clearPairInvitesBetween(
          myDeviceId: myId,
          peerDeviceId: peer.deviceId,
        );
      }
    } catch (e, stack) {
      debugPrint('Çökme sonrası davet temizliği: $e\n$stack');
    }
  }
}
